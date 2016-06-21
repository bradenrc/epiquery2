# vim:ft=coffee

async       = require 'async'
log         = require './util/log.coffee'
_           = require 'lodash-contrib'
path        = require 'path'
fs          = require 'fs'
crypto      = require 'crypto'
core        = require './core.coffee'
config      = require './config.coffee'
query       = require './query.coffee'
templates   = require './templates.coffee'
transformer = require './transformer.coffee'

# regex to replace MS special charactes, these are characters that are known to
# cause issues in storage and retrieval so we're going to switch 'em wherever
# we find 'em
special_characters = {
  "8220": regex: new RegExp(String.fromCharCode(8220), "gi"), "replace": '"'
  "8221": regex: new RegExp(String.fromCharCode(8221), "gi"), "replace": '"'
  "8216": regex:  new RegExp(String.fromCharCode(8216), "gi"), "replace": "'"
  "8217": regex: new RegExp(String.fromCharCode(8217), "gi"), "replace": "'"
  "8211": regex: new RegExp(String.fromCharCode(8211), "gi"), "replace": "-"
  "8212": regex: new RegExp(String.fromCharCode(8212), "gi"), "replace": "--"
  "189": regex: new RegExp(String.fromCharCode(189), "gi"), "replace": "1/2"
  "188": regex: new RegExp(String.fromCharCode(188), "gi"), "replace": "1/4"
  "190": regex: new RegExp(String.fromCharCode(190), "gi"), "replace": "3/4"
  "169": regex: new RegExp(String.fromCharCode(169), "gi"), "replace": "(C)"
  "174": regex: new RegExp(String.fromCharCode(174), "gi"), "replace": "(R)"
  "8230": regex: new RegExp(String.fromCharCode(8230), "gi"), "replace": "..."
}

setupContext = (context, callback) ->
  # making a place to store our stats about our request
  context.Stats = {}
  context.Stats.startDate = new Date()
  context.Stats.templateName = context.templateName
  callback null, context

initializeRequest = (context, callback) ->
  core.trackInflightQuery context.templateName
  if config.isDevelopmentMode()
    templates.init()
    transformer.init()
  log.warn "debug logging enabled for this request" if context.debug
  callback null, context

logTemplateContext = (context, callback) ->
  log.debugRequest context.debug, "[q:#{context.queryId}] template context: #{JSON.stringify context.templateContext}"
  callback null, context

selectConnection = (context, callback) ->
  if not context.connectionConfig
    # no config, need to find one
    if not context.connectionName
      context.emit "no connection specified"
      return callback 'no connection specified'
    context.connection = config.connections[context.connectionName]
    if not context.connection
      msg = "unable to find connection '#{context.connectionName}'"
      context.emit 'error', msg
      return callback msg
  else
    context.connection = connectionConfig

  # Replica check here...
  log.debugRequest context.debug, "[q:#{context.queryId}] context.connection.name", context.connection.name
  if context.connection.replica_of or context.connection.replica_master
    log.debugRequest context.debug, "[q:#{context.queryId}] query is using replica setup"
    if context.rawTemplate.match(/(^|\W)(update|insert|exec|delete)\W/i)
      log.debugRequest context.debug, "[q:#{context.queryId}] Unable to implicitly determine query is replica safe", context.rawTemplate
      if context.rawTemplate.indexOf('replicasafe') != -1
        log.debugRequest context.debug, "query to replica flagged as replicasafe"
      else
        if context.connection.replica_master
          context.emit 'replicamasterwrite', context.queryId
        else
          log.debugRequest context.debug, "[q:#{context.queryId}] query to replica is a write. switching host"
          log.debugRequest context.debug 'hostswitch template:', context.templatePath
          return callback 'replicawrite', context

  context.Stats.connectionName = context.connection.name
  callback null, context

getTemplatePath = (context, callback) ->
  log.debugRequest context.debug, "[q:#{context.queryId}] getting template path for #{context.templateName}"
  # first we make sure that, if we are whitelisting templates, that 
  # our requested template is in a whitelisted directory
  if config.allowedTemplates isnt null
    templateDir = path.dirname context.templateName
    log.debugRequest context.debug, "validating template dir %s against allowed templates", templateDir
    if not config.allowedTemplates[templateDir]
      return callback new Error("Template access denied: " + context.templateName), context
  # if we've arrived here then we've either got no whitelist, or we're running
  # a whitelisted template
  context.templatePath = path.join(config.templateDirectory, context.templateName)
  if not context.templatePath
    callback(new Error "[q:#{context.queryId}] no template path!")
  else
    callback null, context

renderTemplate = (context, callback) ->
  templates.renderTemplate(
    context.templatePath,
    context.templateContext,
    (err, rawTemplate, renderedTemplate) ->
      context.rawTemplate = rawTemplate
      log.debugRequest context.debug, "raw template: \n #{context.rawTemplate}"
      context.renderedTemplate = renderedTemplate
      log.debugRequest context.debug, "rendered template: \n #{context.renderedTemplate}"
      callback err, context
  )

executeQuery = (context, callback) ->
  # if this request is bulk, and we've NOT been told to execute the query
  # we execute. Which is to say the bulk query handling can determine that
  # we have a bulk request but don't need to fire off the query
  if context.requestType is "bulk" and not context.executeBulkQuery
    log.debug "not executing query"
    callback(null, context)
    return
  log.debug "executing query"
  driver = core.selectDriver context.connection
  context.emit 'beginqueryexecution'
  queryCompleteCallback = (err, data) ->
    context.Stats.endDate = new Date()
    if err
      log.error "[q:#{context.queryId}] error executing query #{err}"
      context.emit 'error', err, data

    context.emit 'endquery', data
    core.removeInflightQuery context.templateName
    callback null, context
  query.execute(driver,
    context,
    queryCompleteCallback
  )


collectStats = (context, callback) ->
  stats = context.Stats
  return unless stats
  stats.executionTimeInMillis = stats.endDate.getTime() - stats.startDate.getTime()
  core.QueryStats.buffer.store stats
  # storing the exec time for this query so we can track recent query
  # times by template
  core.storeQueryExecutionTime(
    context.templateName
    stats.executionTimeInMillis
  )
  log.info "[EXECUTION STATS] template: '#{context.templateName}', duration: #{stats.executionTimeInMillis}ms"
  callback null, context

sanitizeInput = (context, callback) ->
  _.walk.preorder context.templateContext, (value, key, parent) ->
    if _.isString value
      _.each Object.keys(special_characters), (keyCode) ->
        def = special_characters[keyCode]
        parent[key] = value.replace def.regex, def.replace

  callback null, context

escapeInput = (context, callback) ->
  _.walk.preorder context.templateContext, (value, key, parent) ->
    if parent
      parent[key] = value.replace(/'/g, "''") if _.isString(value)
  callback null, context

processBulkQueryRequest = (context, callback) ->
  if context.requestType isnt "bulk"
    return callback(null, context)
  keyRequestData = "#{JSON.stringify(_.extend({}, context.requestBody, context.requestQuery))}"
  bulkRequestIdentifier = crypto.createHash('md5').update(keyRequestData).digest("hex")
  log.debug "handling bulk connection request for request with key #{bulkRequestIdentifier}"
  lockFileHandler = (err, fd) ->
    if err?.code is 'EAGAIN'
      # we've encountered an error that indicates that the lock file is in use
      # indicating another epi process is executing this query
      log.debug "couldn't obtain lock for bulk request #{bulkRequestIdentifier}"
      # this is an expected state, so not an error
      err = undefined
      # we're not gonna run a query, so we will have no stats
      context.Stats = undefined
    else # we've locked the file, so we can execute our reqeust as needed
      fs.stat(context.bulkResponseCacheFile, (err, stats) ->
        log.debug "ctime #{stats.ctime.getTime()}"
        log.debug "allowing cache rebuild"
        context.executeBulkQuery = true
        #write to a temp file so we don clobber the cache until we've fully run our query
        cacheFileWriteStream = fs.createWriteStream "#{context.bulkResponseCacheFile}.tmp"
        context.on 'row', (row) ->
          cacheFileWriteStream.write(JSON.stringify(row))
        context.on 'completequeryexecution', () ->
          cacheFileWriteStream.end()
          # now that we're done we can rename our file and 'update' the cache
          fs.rename("#{context.bulkResponseCacheFile}.tmp", context.bulkResponseCacheFile)
          fs.close(fd)
      )
    callback err, context
      
  context.bulkRequestLockfilePath = path.join(config.lockDirectory, "#{bulkRequestIdentifier}.epi.bulk.lock")
  context.bulkRequestIdentifier = bulkRequestIdentifier
  context.bulkResponseCacheFile = path.join(config.bulkCacheDirectory, "#{bulkRequestIdentifier}.epi.bulk.cache")
  context.emit 'bulkqueryrequest'
  # this is our lock file, we're gonna attempt to open it with an exclusive lock
  # ( 0x0020 ) create it if not existant (0x0200) truncate it if it is there
  # ( 0x0400 ) open it async ( 0x0040 ) and most importantly do not block
  # ( 0x0004 )
  fs.open(context.bulkRequestLockfilePath, 0x0020|0x0200|0x0400|0x0040|0x0004, lockFileHandler)

queryRequestHandler = (context) ->
  async.waterfall [
    # just to create our context
    (callback) -> callback(null, context),
    initializeRequest,
    setupContext,
    logTemplateContext,
    getTemplatePath,
    escapeInput,
    sanitizeInput,
    renderTemplate,
    selectConnection,
    processBulkQueryRequest,
    executeQuery,
    collectStats
  ],
  (err, results) ->
    if err
      log.error "[q:#{context.queryId}] queryRequestHandler Error: #{err}"
      context.emit 'error', err
    log.debug "query execution complete"
    context.emit 'completequeryexecution'

module.exports.queryRequestHandler = queryRequestHandler
