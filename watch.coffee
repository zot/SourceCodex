#!/usr/bin/env coffee
fs = require 'fs'
path = require 'path'
child_process = require 'child_process'
util = require 'util'
magic = new (require('mmmagic').Magic)()
w = require 'watch'
_ = require 'lodash'
cs = require 'coffee-script'
acorn = require 'acorn'
acorn.walk = require 'acorn/util/walk'
nodes = require 'coffee-script/lib/coffee-script/nodes'
sqlite3 = require 'sqlite3'
dir = null
verboseLevel = 0
fullDir = null
batch = {}
coffeeFile = /\.coffee$/
indexCoffee = false
indexJs = false
db = null
quiet = false
updateOnly = false
notify = false
ignoreReg = null
rebuild = false

verbose = (level, args...)->
  if !quiet && level <= verboseLevel then write args...

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
      if indexJs then indexJsFile file, text
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
  emitChanges: (notifyReady)->
    if notify
      for file, [type] of @pendingOut
        console.log "#{type} #{file}"
    if notifyReady then verbose 0, "READY"

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
      run "delete from defs where file in (select file from newFiles where state = 'DELETE');"
      run "delete from calls where file in (select file from newFiles where state = 'DELETE');"
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
            @emitChanges true
      run "commit transaction;"
  for file, stat of files
    b.add file, null, stat
  b.run()

checkDb = ->
  if !db
    dbPath = fullDir + '.sourcecodex'
    if rebuild && fs.existsSync dbPath then fs.unlink dbPath
    db = new sqlite3.Database dbPath
    sql """
begin transaction;
create table if not exists files (file primary key, stamp);
create virtual table if not exists lines using fts4 (file, line_number, line, notindexed=line_number, notindexed=file);
create virtual table if not exists lines_terms using fts4aux(lines);
create table if not exists defs(file, code, parent, line_number, col, type);
create table if not exists calls(file, code, call, line_number, col);
create index if not exists sc_1 on defs(file);
create index if not exists sc_2 on defs(file, code);
create index if not exists sc_3 on calls(file);
create index if not exists sc_4 on calls(file, code);
create index if not exists sc_5 on calls(file, call);
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

class CSNodes
  constructor: (node)->
    @node = (if typeof node == 'string'
      if m = node.match /\.(lit)?coffee$/ then cs.nodes(node, literate: m[1]?) else null
    else node)
  traverse: (func)-> @subtraverse @node, func
  subtraverse: (node, func)->
    func node, => node.eachChild (child)=> @subtraverse child, func
  findCallGraph: (callback)->
    context = []
    topVars = vars = {}
    @traverse (node, cont)=>
      if node instanceof nodes.Code
        if node.assignment then context.push node.assignment.base
        oldVars = vars
        vars = __proto__: oldVars
        cont()
        vars = oldVars
        if node.assignment then context.pop()
      else
        if @isVarAssign node
          for [n, v] in @assigns node.variable, node.value, []
            if n != _.last(context)
              callback.def (if v instanceof nodes.Code then 'function' else 'variable'), @parent(n, context, topVars, node), n, n.value, n.locationData.first_line + 1, n.locationData.first_column
              vars[n.value] = true
        else if node instanceof nodes.Class
          write "CLASS: #{util.inspect node}"
          node.variable.def = true
          v = node.variable.base
          callback.def 'class', @parent(node, context, topVars), node, v.value, v.locationData.first_line + 1, v.locationData.first_column
          vars[node.value] = true
        else if @isRef node, context
          if node.base.value[0].match /[_$a-zA-Z]/
            b = node.base
            callback.call _.last(context)?.value || '', node, b.value, b.locationData.first_line + 1, b.locationData.first_column
        cont()
  parent: (node, context, topVars, assignNode)->
    if context.length == 0 || node.propertyReference || topVars[node.value] || assignNode.context == 'object' then ''
    else _.last(context).value
  isVarAssign: (node)-> node instanceof nodes.Assign
  isRef: (node, context)->
    node instanceof nodes.Value && !node.def && node.base instanceof nodes.Literal
  assigns: (variable, value, result)->
    if variable.base instanceof nodes.Literal
      if value instanceof nodes.Code
        value.assignment = variable
      if variable.properties.length
        prop = _.last(variable.properties).name
        prop.propertyReference = true
        result.push [prop, value]
      else
        variable.def = true
        result.push [variable.base, value]
    else if variable.base instanceof nodes.Arr
      for i in [0...variable.base.objects.length]
        @assigns variable.base.objects[i], value.base.objects[i], result
    else if variable.base instanceof nodes.Obj
      if value.base instanceof nodes.Obj
        obj = {}
        o = value.base
        for prop in [0...o.properties.length]
          obj[o.properties[prop].variable.name] = o.properties[prop].variable.value
        for i in [0...variable.base.properties.length]
          @assigns variable.base.properties[i], obj[variable.base.properties[i].base.value], result
      else
        for i in [0...variable.base.properties.length]
          @assigns variable.base.properties[i], null, result
    else write "UNKNOWN TYPE OF ASSIGNMENT: #{variable.base.constructor.name} #{util.inspect variable}"
    result

class JSNodes
  constructor: (source)->
    @node = acorn.parse source
    lines = source.split /(\r?\n)/
    @lineIndices = [0]
    for i in [0...lines.length] by 2
      @lineIndices.push _.last(@lineIndices) + lines[i].length + (lines[i + 1] || '').length
  position: (index)->
    i = _.sortedIndex @lineIndices, index + 1
    [i, index - (@lineIndices[i - 1] || 0)]
  nodeKey: (node)-> node.type + node.start
  findCallGraph: (callback)->
    context = []
    objects = []
    seen = {}
    p = (node, state, override)=>
      func = call = line = col = null
      if !override
        key = @nodeKey node
        refType = 'function'
        if !seen[key]
          seen[key] = true
          if node.type == 'CallExpression'
            call = node.callee
          else if node.type == 'AssignmentExpression' && node.left.type == 'Identifier' && node.right.type == 'FunctionExpression'
            func = node.left
          else if node.type == 'AssignmentExpression' && node.left.type == 'MemberExpression' && node.right.type == 'FunctionExpression'
            func = node.left.property
          else if node.type == 'FunctionDeclaration'
            func = node.id
          else if node.type == 'ObjectExpression'
            objects.push node
            prop = 0
            for {key, value} in node.properties
              value.propNum = prop++
          else if node.type == 'FunctionExpression' && node.propNum?
            func = _.last(objects).properties[node.propNum].key
          if func
            context.push func
            [line, col] = @position func.start
            callback.def refType, '', node, func.name, line, col
            verbose 1, "# DEF: #{func.name} #{line} #{col}"
          else if call
            [line, col] = @position call.start
            callback.call _.last(context).name, node, call.name, line, col
            verbose 1, "# CALL: #{_.last(context).name} #{call.name} #{line} #{col}"
          verbose 1, "  NODE: #{node.type}, override: #{override}"
      acorn.walk.base[override || node.type] node, state, p
      if func then context.pop()
      else if node.type == 'ObjectExpression' then objects.pop()
    p @node, null
    write "done"

indexCoffeeFile = (fpath, source)->
  if m = fpath.match /\.(lit)?coffee$/
    sql "delete from defs where file = '#{fpath}'", "delete from calls where file = '#{fpath}'"
    new CSNodes(cs.nodes(source, literate: m[1]?)).findCallGraph
      def: (refType, parent, node, name, line, col)->
        sql "insert into defs values ('#{fpath}', '#{name}', '#{parent}', #{line}, #{col}, '#{refType}');"
      call: (def, node, name, line, col)->
        sql "insert into calls values ('#{fpath}', '#{def}', '#{name}', #{line}, #{col});"

indexJsFile = (fpath, source)->
  if fpath.match(/\.js$/) && fpath == 'test.js'
    fs.readFile fpath, (err, result)->
      sql "delete from defs where file = '#{fpath}'", "delete from calls where file = '#{fpath}'"
      new JSNodes(result.toString()).findCallGraph
        def: (refType, parent, node, name, line, col)->
          sql "insert into defs values ('#{fpath}', '#{name}', '#{parent}', #{line}, #{col}, '#{refType}');"
        call: (def, node, name, line, col)->
          sql "insert into calls values ('#{fpath}', '#{def}', '#{name}', #{line}, #{col});"

#####################
# Argument processing
#####################

usage = (msgs...)->
  if msg.length > 0 then console.log msgs...
  console.log """
Usage #{process.argv[0]} [-i IGNOREPAT | -v | -r | -c | -j | -u | -q | -n ] DIR
DIR is the directory containing the files to monitor.
OPTIONS:
  -h            Help: print this message
  -i IGNOREPAT  Pattern of files not to monitor
  -v            Increase verbosity
  -r            Remove and rebuild database
  -c            Index CoffeeScript files
  -j            Index JavaScript files
  -u            Update only -- exit after updating
  -q            Don't emit file tree modification messages
  -n            Output changes: 'CREATE'|'MODIFY'|'DELETE' FILE
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
      when '-r' then rebuild = true
      when '-c' then indexCoffee = true
      when '-j' then indexJs = true
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
