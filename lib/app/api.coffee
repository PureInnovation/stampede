###

API application service to fit into the stampede app framework.

###

stampede = require '../stampede'
events = require 'events'
express = require 'express'
http = require 'http'
io = require 'socket.io'
fs = require 'fs'


log = stampede.log

sioLogger = require './sioLogger'
service = require './service'


class apiRequest
	parentApi:				undefined
	isExpress:				false
	isInternal:				false
	params:					undefined
	routeVars:				undefined
	args:					undefined
	expressReq:				undefined
	expressRes:				undefined
	expressNext:			undefined
	responseSent:			false
	pgDbList:				undefined
	pgNamed:				undefined
	url:					''

	constructor: (p) ->
		@parentApi = p
		@routeVars = {}
		@pgDbList = []
		@pgNamed = {}
		@params = {}

	setExpress: (@isExpress = false, @expressReq, @expressRes, @expressNext) -> @
	
	setParams: (@params) -> @

	param: (v) -> @params[v]

	setParam: (k, v) ->
		@params[k] = v
		@

	route: (v) -> @routeVars[v]

	setRouteVars: (@routeVars) -> @

	setUrl: (@url) -> @
	getUrl: -> @url

	arg: (v) ->
		if @isExpress is true
			@expressReq.param[v]
		else
			undefined

	queryArg: (v) ->
		if @isExpress is true
			@expressReq.query[v]
		else
			undefined

	bodyArg: (v) ->
		if @isExpress is true
			@expressReq.body[v]
		else
			undefined

	getService: -> @parentApi

	getConfig: -> @parentApi.getConfig()

	getApp: -> @parentApi.getApp()

	connectPostgres: (dbName, callback) ->
		db = @parentApi.getApp().connectPostgres dbName, => 
			unless err?
				@pgDbList.push dbh
				@firstSetPgConnection dbName, dbh

			process.nextTick => callback err, dbh

	firstSetPgConnection: (dbName, dbh) ->
		unless @pgNamed[dbName]? then @pgNamed[dbName] = dbh
		@

	setPgConnection: (dbName, dbh) ->
		@pgNamed[dbName] = dbh
		@

	getPgConnection: (dbName) -> @pgNamed[dbName]
	getPostgresDbh: (dbName) -> @pgNamed[dbName]

	finish: ->
		for dbh in @pgDbList when dbh?
			dbh.disconnect()

	send: (response = {}, doNotFinish = false) ->
		# Tidy up and close our connections
		@finish() unless doNotFinish is true

		if @isExpress is true
			@expressRes.json response
		else
			console.log "Eh?  Dunno how to send (api.coffee)"

	sendError: (error, detail = undefined, doNotFinish = false) ->
		errObj = { error: error, url: @url }
		if detail? then errObj.detail = detail

		@send errObj, doNotFinish

	notFound: ->
		if @isExpress is true
			@responseSent = true
			@expressNext()
		else
			console.log "Unhandled Not Found within apiRequest."


class module.exports extends service
	@apiRequest:			apiRequest
	# @apiResponse:			apiResponse

	devMode:				true						# If true then we are in dev mode and additional instrumentation and logging is provided
	httpServer:				undefined					# Our Node.JS HTTP or HTTPS server
	expressApp:				undefined					# The express application upon which our API app will be built
	socketIo:				undefined					# The instance of socket.io that will provide our real time communication
	socketIoLogger:			undefined					# The instance of our logger that will bridge socket.io's logging with that of stampede
	router:					undefined
	handlers:				undefined

	name:					'Unnamed API Service'		# For reporting and logging we can name our service

	constructor: (app, config, bootConfig) ->
		super app, config, bootConfig
		@router = new stampede.router()
		@handlers = {}


	start: (done) ->
		# Create our express app, http service and socket.io instance and connect them all together
		@socketIoLogger = new sioLogger(log)
		@expressApp = express()
		@httpServer = http.createServer @expressApp
		@socketIo = io.listen @httpServer, { logger: @socketIoLogger }

		# Set up our express middleware
		@expressApp.use express.compress()
		@expressApp.use @expressRequest
		@expressApp.use (req, res, next) =>
			res.send 404, 'Sorry could not find that!'
		@expressApp.use (err, req, res, next) =>
			res.send 500, "We made a boo boo: #{err}"

		# Fire up the server on the appropriate port
		port = @config[@name]?.port ? 8080
		@httpServer.listen port

		@socketIo.sockets.on 'connection', (socket) =>
			socket.set 'controllerObject', @

		# We're all done
		log.info "#{@name} started on port #{port}."

		# Call back to our parent
		super done

	expressRequest: (req, res, next) =>
		# Does the request match anything in our router?
		match = @router.find req.path

		# If we don't have a match tell express to move on to the next handler
		unless match?
			log.debug "Route for url '#{req.path}' not found."
			return next()

		log.debug "Route for url '#{req.path}' was found."

		# We have a match, let's build up the internal request object
		apiReq = new apiRequest(@)
		apiReq.setExpress true, req, res, next
			.setRouteVars match.vars
			.setUrl req.path

		method = req.method.toLowerCase()

		# Do we have a matching definition for our method type?
		if match.route[method]?
			log.debug "Handler for method #{method} was found"
			# Build up our params objects
			match.route[method+'BuildParams'] apiReq, (err) =>
				# If there's an error building our parameters then send the error respond
				if err?
					log.debug "Error building params"
					apiReq.sendError err
				else
					log.debug "Params processed"
					# We have everything we need to generate our reponse, first let's see if we have a simple function to call
					if stampede._.isFunction match.route[method]
						log.debug "Calling handler function"
						match.route[method] apiReq, (response) =>
							apiReq.send response
					else
						# Nope, okay let's go through our checks for the clever bits of automated functionality
						log.debug "Auto DB request found"
						@autoRequestDb match.route[method], apiReq
		else
			log.debug "Handler for method #{method} was not found"
			next()

	autoRequestDb: (route, apiReq) ->
		if route.db?
			apiReq.connectPostgres route.db, (err, dbh) =>
				if err? 
					apiReq.sendError err
				else
					@autoRequestRunQuery route, apiReq, dbh
		else
			apiReq.sendError "No DB connection specified"

	autoRequestRunQuery: (route, apiReq, dbh) ->
		if route.fetchAll? and route.fetchOne?
			apiReq.error "Only one of fetchAll and fetchOne can be defined"
		else if route.fetchAll? or route.fetchOne?
			# Map any bind variables to our validated parameters
			bind = (apiReq.param(k) for k in (route.bind ? []))

			# Execute the query
			dbh.query (route.fetchAll ? route.fetchOne), bind, (err, res) =>
				if err?
					apiReq.sendError "Error running query: #{err}"
				else
					if route.fetchOne? and res.rows.length > 1
						apiReq.sendError "fetchOne returned more than one result"
					else if res.rows.length is 0
						apiReq.notFound()
					else
						# Pass our results on to the filter
						@autoRequestFilter route, apiReq, dbh, res.rows, route.fetchOne?
		else
			apiReq.error "Either fetchAll or fetchOne must be defined"

	autoRequestFilter: (route, apiReq, dbh, res, fetchOne) ->
		if route.filter?
			# Use async to process each result row, filtering the result back into our result object
			stampede.async.map res, (item, callback) =>
				if route.filter.length is 2 then route.filter item, callback
				else route.filter apiReq, item, callback
			, (err, results) =>
				if err?
					apiReq.error err
				else if fetchOne
					if route.send? then route.send apiReq, results[0]
					else apiReq.send results[0]
				else
					results = stampede._.compact results
					if route.send? then route.send apiReq, results
					else apiReq.send results
		else
			if fetchOne
				if route.send? then route.send apiReq, res[0]
				else apiReq.send res[0]
			else
				if route.send? then route.send apiReq, res
				else apiReq.send res


	addHandlerDirectory: (path, done) ->
		path = @filepath path
		log.debug "Adding handler directory #{path}"

		# Open the directory asynchronously so we can scan through its files
		fs.readdir path, (err, files) =>
			if err?
				log.error "Error scanning directory '#{path}': #{err}"
				return done(err)

			# For each file in our directory we're going to require it and then scan it for routes
			for file in files when not @handlers[path + '/' + file]?
				log.debug "Loading handler #{path + '/' + file}"
				h = require path + '/' + file
				@handlers[path + '/' + file] = h

				# Scan through the handler for routes that can be added to the router
				for name, route of h when stampede._.isFunction(route)
					log.debug "Checking potential route #{name}"
					
					# Temporarily instance the route
					i = new route()
					if i instanceof stampede.route
						log.debug "Route #{name} is valid, installing in our router."
						@router.addRoute i
					else
						log.debug "Route #{name} is not a stampede route."

			process.nextTick => done()
		@
