#!/usr/bin/env coffee
fs = require 'fs'
path = require 'path'
child_process = require 'child_process'
magic = new (require('mmmagic').Magic)()
w = require 'watch'
_ = require 'lodash'
cs = require 'coffee-script'
nodes = require 'coffee-script/lib/coffee-script/nodes'
sqlite3 = require 'sqlite3'
dir = null
verboseLevel = 0
fullDir = null
batch = {}
coffeeFile = /\.coffee$/
indexCoffee = false
db = null
util = require 'util'
quiet = false
updateOnly = false
notify = false
ignoreReg = null

verbose = (level, args...)->
  if !quiet && verboseLevel <= level then write args...

write = (args...)-> process.stderr.write args.join(' ') + '\n'

# returns [exit, output]
simpleSpawn = (cmd, args...)->
  proc = child_process.spawn cmd, args
  proc.on

shouldUse = (f)->
  f = path.resolve f
  if f.substring(0, fullDir.length) == fullDir then f = f.substring fullDir.length
  !(ignoreReg.test f) && f

escapeGlob = (ex)-> ex.replace(/[.\\]/g, '\\$&').replace(/\*/g, '.*')

computeIgnore = (ignores)->
  ignore = '^.sourcecodex$'
  for ig in ignores
    if ig != '/'
      if ig[0] == '/' then ignore = "#{ignore}|^#{escapeGlob ig.substring 1}(\\\\|$)"
      else ignore = "#{ignore}|(^|\\\\)#{escapeGlob ig}(\\\\|$)"
  ignoreReg = new RegExp ignore

monitor = (dir)->
  batch = new Batch
  fullDir = "#{path.resolve(dir)}\\"
  opts =
    ignoreUnreadableDir: true
    filter: (file)-> shouldUse file
  verbose 1, "MONITOR: #{dir}"
  w.createMonitor dir, opts, (mon)->
    processInitialFiles mon.files
    if updateOnly
      write 'exiting'
      mon.stop()
      db.close()
      process.exit 0
    mon.on 'created', (f, stat)-> processChange 'CREATE', f, stat
    mon.on 'changed', (f, stat)-> processChange 'MODIFY', f, stat
    mon.on 'removed', (f, stat)-> processChange 'DELETE', f, stat

#Throttle batch processing to run only every 1/10 second
flush = _.throttle (->
  b = batch
  batch = new Batch
  b.run()), 100, trailing: true

processChange = (type, f, stat)->
  batch.add f, type, stat
  flush()

#####################
# Database
#####################

escapeString = (str)-> str.replace /'/g, "''"

class Batch
  constructor: ->
    @queued = 0
    @pendingOut = {}
    @added = {}
  add: (file, type, stat)->
    if shouldUse file
      @pendingOut[file] = [type, stat.mtime.getMilliseconds()]
      @queued++
  run: ->
    for file, [type] of @pendingOut
      if type == 'DELETE' then @dequeue()
      else
        fs.readFile path.resolve(fullDir, file), do (file)=> (e, buf)=>
          if e then @dequeue()
          else magic.detect buf, (e, result)=>
            if !e && result.match /text/ then @added[file] = buf.toString()
            @dequeue()
  queue: -> @queued++
  dequeue: ->
    if --@queued == 0
      @processBatch()
  addLines: (file)->
    if text = @added[file]
      l = 1
      for line in text.split /\n\r?/
        run "insert into lines values ('#{file}', #{l}, '#{escapeString line}');"
        l++
      if indexCoffee then indexCoffeeFile file, text
  processBatch: ->
    runSql =>
      run "begin transaction;"
      for file, [type, stamp] of @pendingOut
        run "delete from lines where file = '#{file}';"
        if type == 'DELETE' then run "delete from files where file = '#{file}'"
        else run "insert or replace into files values ('#{escapeString file}', #{stamp})"
        @addLines file
      run "end transaction;"
    @emitChanges()
  emitChanges: ->
    if notify
      for file, [type] of @pendingOut
        console.log "#{type} #{file}"
    verbose 0, "READY"

processInitialFiles = (files)->
  tot = 0
  if !quiet
    for file of files
      tot++
    verbose 0, "Checking #{tot} files for updates"
  b = new Batch
  b.processBatch = ->
    newFiles = []
    runSql =>
      run "begin transaction;"
      run "create temp table currentFiles(file primary key, stamp, state);"
      for file, [type, stamp] of @pendingOut
        if shouldUse file
          run "insert into currentFiles values ('#{file}', #{stamp}, 'CREATE');\n"
      run "update currentFiles set state = 'MODIFY' where file in (select file from files);"
      run """
  create temp table newFiles as
    select currentFiles.file as file, currentFiles.state, currentFiles.stamp
      from currentFiles left join files on currentFiles.file = files.file
      where files.file is null or files.stamp < currentFiles.stamp;
  """
      run """
  insert into newFiles
    select files.file, 'DELETE', currentFiles.stamp
      from files left join currentFiles on currentFiles.file = files.file
      where currentFiles.file is null;
  """
      run "delete from files where file not in (select file from currentFiles);"
      run "delete from lines where file not in (select file from currentFiles);"
      run "insert or replace into files select file, stamp from currentFiles where state != 'DELETE';"
      run "delete from coffee_defs where file in (select file from newFiles where state = 'DELETE');"
      run "delete from coffee_calls where file in (select file from newFiles where state = 'DELETE');"
      db.each "select * from (select file, state, stamp, 1 as ord from newFiles union values (null, null, null, 2)) order by ord;", (err, row)=>
        if err then write "ERROR: #{err}"
        else if row.file != null then newFiles.push row
        else
          @pendingOut = {}
          runSql =>
            run "begin transaction;"
            for row in newFiles
              @addLines row.file
              @pendingOut[row.file] = [row.state, row.stamp]
            run "commit transaction;"
            @emitChanges()
      run "commit transaction;"
  for file, stat of files
    b.add file, null, stat
  b.run()

checkDb = ->
  if !db
    db = new sqlite3.Database(fullDir + '.sourcecodex')
    sql """
begin transaction;
create table if not exists files (file primary key, stamp);
create virtual table if not exists lines using fts4 (file, line_number, line, notindexed=line_number, notindexed=file);
create virtual table if not exists lines_terms using fts4aux(lines);
create table if not exists coffee_defs(file, code, line_number, col);
create table if not exists coffee_calls(file, code, call, line_number, col);
create index if not exists coffee_1 on coffee_defs(file);
create index if not exists coffee_2 on coffee_defs(file, code);
create index if not exists coffee_3 on coffee_calls(file);
create index if not exists coffee_4 on coffee_calls(file, code);
create index if not exists coffee_5 on coffee_calls(file, call);
commit transaction;
""".split('\n')...

sql = (strs...)->
  runSql ->
    for str in strs
      run str

runSql = (block)->
  checkDb()
  db.serialize block

run = (statement)->
  db.run statement, (err)->
    if err then write "Error in SQL: #{statement}...\n#{err}\n"

#####################
# Call graphs
#####################

class NodeStack
  constructor: ->
    @parentStack = []
    @contextStack = []
  pushNode: (node)-> @parentStack.push node
  popNode: -> @parentStack.pop()
  pushContext: (name)-> @contextStack.push name
  popContext: -> @contextStack.pop()
  topNode: -> _.last @parentStack
  topContext: -> _.last @contextStack
  contextPad: ->
    pad = ''
    for i in [0...@contextStack.length]
      pad += '  '
    pad

stackTraverseNode = (node, func)-> substackTraverse node, new NodeStack(), func

substackTraverse = (node, stack, func)->
  func node, stack, ->
    stack.pushNode node
    node.eachChild (child)-> substackTraverse child, stack, func
    stack.popNode()

isDef = (node)-> node instanceof nodes.Assign && node.value instanceof nodes.Code

isCall = (node)->
  node instanceof nodes.Call &&
  node.variable instanceof nodes.Value

indexCoffeeFile = (fpath, source)->
  if m = fpath.match /\.(lit)?coffee$/
    sql "delete from coffee_defs where file = '#{fpath}'", "delete from coffee_calls where file = '#{fpath}'"
    stackTraverseNode cs.nodes(source, literate: m[1]?), (node, stack, cont)->
      if isDef node
        v = node.variable
        stack.pushContext v.base.value
        sql "insert into coffee_defs values ('#{fpath}', '#{v.base.value}', #{v.locationData.first_line + 1}, #{v.locationData.first_column});"
        cont()
        stack.popContext()
      else
        if isCall node
          v = node.variable
          sql "insert into coffee_calls values ('#{fpath}', '#{stack.topContext()}', '#{v.base.value}', #{v.locationData.first_line + 1}, #{v.locationData.first_column});"
        cont()


#####################
# Argument processing
#####################

usage = (msgs...)->
  if msg.length > 0 then console.log msgs...
  console.log """
Usage #{process.argv[0]} [-i IGNOREPAT | -v] DIR
DIR is the directory containing the files to monitor.
OPTIONS:
  -h            Help: print this message
  -i IGNOREPAT  Pattern of files not to monitor
  -v            Increase verbosity
  -c            Index CoffeeScript files
  -u            Update only -- exit after updating
  -q            Don't emit file tree modification messages
"""
  process.exit 1

processArgs = ->
  pos = 2
  ignores = []
  while pos < process.argv.length
    switch arg = process.argv[pos]
      when '-h' then usage()
      when '-i' then ignores.push process.argv[++pos]
      when '-v'
        verboseLevel++
        quiet = false
      when '-c' then indexCoffee = true
      when '-q' then if verboseLevel == 0 then quiet = true
      when '-u' then updateOnly = true
      when '-n'
        notify = true
        if verboseLevel == 0 then quiet = true
      else
        if arg[0] == '-' then usage "Unrecognized switch #{arg}"
        else dir = process.argv[pos]
    pos++
  verbose 1, process.argv...
  if !dir then usage()
  computeIgnore ignores
  monitor dir

processArgs()
