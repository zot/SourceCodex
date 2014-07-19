#!/usr/bin/env coffee
path = require 'path'
w = require 'watch'
_ = require 'lodash'
ignore = null
dir = null
verboseOn = false
ignoreReg = null
fullDir = null
pendingOut = {}

verbose = (args...)-> if verboseOn
  process.stderr.write args.join(' ') + '\n'

shouldUse = (f)->
  f = path.resolve f
  if f.substring(0, fullDir.length) == fullDir then f = f.substring fullDir.length
  !(ignoreReg.test f) && f

monitor = (dir, ignores)->
  fullDir = "#{path.resolve(dir)}\\"
  ignoreReg = new RegExp ignores
  opts = ignoreUnreadableDir: true
  if ignores then opts.filter = (file)-> shouldUse file
  verbose "MONITOR: #{dir}"
  w.createMonitor dir, opts, (mon)->
    mon.on 'created', (f, stat)-> burp 'CREATE', f
    mon.on 'changed', (f, stat)-> burp 'MODIFY', f
    mon.on 'removed', (f, stat)-> burp 'DELETE', f

flush = _.throttle (->
  console.log 'BEGIN'
  for file, type of pendingOut
    console.log type, file
  console.log 'END'), 200, trailing: true

burp = (type, f)-> if f = shouldUse f
  pendingOut[f.replace /\\/g, '/'] = type
  flush()

usage = ->
  console.log """
Usage #{process.argv[0]} [-i IGNOREPAT | -v] DIR
DIR is the directory containing the files to monitor.
OPTIONS:
  -i IGNOREPAT  Pattern of files not to monitor
  -v            Turn on verbose
"""

processArgs = ->
  pos = 2
  while pos < process.argv.length
    switch process.argv[pos]
      when '-i' then ignore = process.argv[++pos]
      when '-v' then verboseOn = true
      else dir = process.argv[pos]
    pos++
  verbose process.argv...
  if !dir then usage()
  monitor dir, ignore

processArgs()
