# Copyright (C) 2012 Avi Romanoff <aviromanoff at gmail.com>

_            = require "underscore"
async        = require "async"
http         = require "http"
colors       = require "colors"
cheerio      = require "cheerio"
mongoose     = require "mongoose"
moment       = require "moment"
querystring  = require "querystring"

logging      = require "./logging"
secrets      = require "./secrets"

String::capitalize = ->
  @charAt(0).toUpperCase() + @slice 1

mongoose.connect secrets.MONGO_URI

# [18:46] <timoxley> UserSchema.namedScope('forAccount', function (account) {
# [18:46] <timoxley>   return this.find({accountId: account})
# [18:46] <timoxley> })
# [18:47] <timoxley> then I say User.forAccount(currentAccount._id).find(…)
# [18:47] <timoxley> which scopes the find() query to the current "Account"

AccountSchema = new mongoose.Schema
  _id: String
  nickname: String
  is_new:
    type: Boolean
    default: true
  firstrun:
    type: Boolean
    default: true
  details:
    type: Boolean
    default: true
  updated: # Start off at the beginning of UNIX time so it's initially stale.
    type: Date
    default: new Date 0

Account = mongoose.model 'account', AccountSchema

# jbha_id is the content id for a course
# or assignment on the jbha.org website's
# database. It is used as a unique index
# to ensure that doing a fetch does not 
# result in duplicates being stored.
CourseSchema = new mongoose.Schema
  owner: String
  title: String
  jbha_id:
    type: String
    index:
      unique: false
      sparse: true
  teacher: String
  assignments: [{ type: mongoose.Schema.ObjectId, ref: 'assignment' }]
  details: String

Course = mongoose.model 'course', CourseSchema

AssignmentSchema = new mongoose.Schema
  owner: String
  date: Number
  title: String
  details: String
  jbha_id:
    type: String
    index:
      unique: false
      sparse: true
  archived:
    type: Boolean
    default: false
  done:
    type: Boolean
    default: false

Assignment = mongoose.model 'assignment', AssignmentSchema

logger = new logging.Logger "API"

Jbha = exports

L = (prefix, message, urgency="debug") ->
  logger[urgency] "#{prefix.underline} :: #{message}"

exports.silence = () ->
  L = () ->
    # pass

Jbha.Client =

  # Logs a user into the homework website.
  # Returns ``true`` to ``cb`` if authentication was successful.
  # Returns ``false`` to ``cb`` if authentication failed.
  authenticate: (username, password, cb) ->
    username = username.toLowerCase()

    post_data = querystring.stringify
      Email: "#{username}@jbha.org"
      Passwd: password
      Action: "login"

    options =
      host: "www.jbha.org"
      path: "/students/index.php"
      method: 'POST'
      headers:
        'Content-Type': 'application/x-www-form-urlencoded'
        'Content-Length': post_data.length

    req = http.request options, (res) =>
      res.on 'end', () =>
        if res.headers.location is "/students/homework.php"
          L username, "Remote authentication succeeded", "info"
          Account
            .findOne()
            .where('_id', username)
            .run (err, account_from_db) =>
              return if @_call_if_truthy err, cb
              cookie = res.headers['set-cookie'][1].split(';')[0]
              account = account_from_db or new Account()
              res =
                token:
                  cookie: cookie
                  username: username
                is_new: account.is_new
              if account_from_db
                cb null, res
              else
                account.nickname = username.split('.')[0].capitalize()
                account._id = username
                account.save (err) =>
                  return if @_call_if_truthy err, cb
                  cb null, res

        else
          L username, "Remote authentication failed", "warn"
          @_call_if_truthy "Invalid login", cb

    req.write post_data
    req.end()

  # Used ONLY for testing
  _create_account: (username, cb) ->
    account = new Account()
    account._id = username
    account.nickname = "TestAccount"
    account.save (err, doc) =>
      return if @_call_if_truthy err, cb
      cb null,
        account:
          doc
        token:
          cookie: "1235TESTCOOKIE54321"
          username: doc._id

  read_settings: (token, cb) ->
    Account
      .findOne()
      .where('_id', token.username)
      .select(['nickname', 'details', 'is_new', 'firstrun', 'updated'])
      .run cb

  update_settings: (token, settings, cb) ->
    Account.update _id: token.username,
      nickname: settings.nickname
      details: settings.details
      firstrun: settings.firstrun,
      cb

  _delete_account: (token, account, cb) ->
    async.parallel [
      (callback) ->
        Account
          .where('_id', account)
          .remove callback
      (callback) ->
        Course
          .where('owner', account)
          .remove callback
      (callback) ->
        Assignment
          .where('owner', account)
          .remove callback
    ], cb

  # JSON-ready dump of an account's courses and assignments
  by_course: (token, cb) ->
    Course
      .where('owner', token.username)
      .populate('assignments', ['title', 'archived', 'details', 'date', 'done', 'jbha_id'])
      .exclude(['owner', 'jbha_id'])
      .run (err, courses) =>
        @_call_if_truthy(err, cb)
        cb courses

  create_assignment: (token, data, cb) ->
    async.waterfall [

      (wf_callback) ->
        Course
          .findById(data.course)
          .run wf_callback

      (course, wf_callback) ->
        assignment = new Assignment()
        assignment.owner = token.username
        assignment.title = data.title
        assignment.date = data.date
        assignment.details = data.details
        assignment.save (err) ->
          wf_callback err, course, assignment

      (course, assignment, wf_callback) ->
        course.assignments.push assignment
        course.save (err) ->
          wf_callback err, course, assignment

    ], (err, course, assignment) ->
      delete assignment["owner"]
      cb err, course, assignment

  update_assignment: (token, assignment, cb) ->
    # Pull the assignment from the current course,
    # push it onto the new one, save it,
    # and finally update the assignment fields. 
    async.waterfall [
      (wf_callback) ->
        Course.update {
          owner: token.username
          assignments: assignment._id
        },
        {
          $pull: {assignments: assignment._id}
        },
        {},
        (err) ->
          wf_callback()
      (wf_callback) ->
        Course
          .findOne()
          .where('owner', token.username)
          .where('_id', assignment.course)
          .run wf_callback
      (course, wf_callback) ->
        course.assignments.push assignment._id
        course.save wf_callback
    ], (err) ->
      Assignment.update {
          owner: token.username
          _id: assignment._id
        },
        {
          title: assignment.title
          date: assignment.date
          details: assignment.details
          done: assignment.done
          archived: assignment.archived
        },
        {},
        cb

  delete_assignment: (token, assignment, cb) ->
    Assignment
      .where('owner', token.username)
      .where('_id', assignment._id)
      .remove cb

  create_course: (token, data, cb) ->
    course = new Course()
    course.owner = token.username
    course.title = data.title
    course.teacher = data.teacher
    course.save cb

  update_course: (token, course, cb) ->
    Course.update {
        owner: token.username
        _id: course._id
      },
      {
        title: course.title
        teacher: course.teacher
      },
      cb

  delete_course: (token, course, cb) ->
    Course
      .where('owner', token.username)
      .where('_id', course._id)
      .remove cb

  keep_alive: (token, cb) ->
    @_authenticated_request token.cookie, "homework.php", (err, $) ->
      cb err

  refresh: (token, options, cb) ->

    @_parse_courses token.cookie, (courses) =>

      # Counter for the number of assignments that were
      # added that didn't exist in the database before.
      new_assignments = 0

      parse_course = (course_data, course_callback) =>
        # Get the DOM of the course webpage
        @_authenticated_request token.cookie, "course-detail.php?course_id=#{course_data.id}", (err, $) =>
          async.waterfall [

            # Query the database for the course
            (wf_callback) =>
              Course
                .findOne()
                .where('owner', token.username)
                .where('jbha_id', course_data.id)
                .populate('assignments')
                .run wf_callback

            # Pass the course along, or create a new
            # one if it didn't exist in the database.
            (course_from_db, wf_callback) =>
              if not course_from_db
                course = new Course()
                course.owner = token.username
                course.title = course_data.title
                course.jbha_id = course_data.id
                course.teacher = $("h1.normal").text().split(":").slice(0)[0]
              else
                course = course_from_db
              wf_callback null, course

            # Iterate over the DOM and parse the assignments, saving
            # them to the database if needed.
            (course, wf_callback) =>
              parse_assignment = (element, assignment_callback) =>
                # Looks like: ``Due May 08, 2012: Test: Macbeth``
                text_blob = $(element).text()
                # Skips over extraneous and unwanted matched objects,
                # like course policies and stuff.
                if text_blob.match /Due \w{3} \d{1,2}\, \d{4}:/
                  # Parse _their_ assignment id
                  assignment_id = $(element).attr('href').match(/\d+/)[0]

                  # Get the assignment with the jbha_id we're currently parsing,
                  # if one exists, or return ``undefined``.
                  assignment_from_db = _.find course.assignments, (assignment) ->
                    true if assignment.jbha_id is assignment_id

                  if assignment_from_db
                    assignment_callback null
                    return

                  splits = text_blob.split ":"
                  assignment_title = splits.slice(1)[0].trim()
                  # Force EDT timezone and parse their date format
                  # into a UNIX epoch timestamp.
                  assignment_date = Date.parse(splits.slice(0, 1) + " EDT")
                  # Parse the details of the assignment as HTML -- **not** as text.
                  assignment_details = $("#toggle-cont-#{assignment_id}").html()

                  # If there is some text content -- not just empty tags, we assume
                  # there are relevant assignment details and sanitize them.
                  if $("#toggle-cont-#{assignment_id}").text()
                    # These regexes are sanitizers that:
                    # 
                    # - Strip all header elements.
                    # - Strip all in-line element styles.
                    regexes = [/\<h\d{1}\>/gi, /\<\/h\d{1}\>/gi, /style="(.*?)"/gi]
                    for regex in regexes
                      assignment_details = assignment_details.replace regex, ""
                    # Make jbha.org relative links absolute.
                    assignment_details = assignment_details.replace /href="\/(.*?)"/, 'href="http://www.jbha.org/$1"'
                  else 
                    # If there's no assignment details, set it to null.
                    assignment_details = null

                  assignment = new Assignment()
                  assignment.owner = token.username
                  assignment.title = assignment_title
                  assignment.jbha_id = assignment_id
                  assignment.details = assignment_details
                  assignment.date = assignment_date

                  # Add the assignment (really just the assignment ObjectId)
                  # on to the course's assignments array.
                  course.assignments.push assignment

                  # Increment the new assignments counter
                  new_assignments++

                  # Mark assignments in the past as done and archived
                  # if the option was specified.
                  if options and options.archive_if_old
                    if assignment_date < Date.now()
                      assignment.done = true
                      assignment.archived = true
                  assignment.save (err) =>
                    assignment_callback err
                else
                  assignment_callback err

              async.forEach $('a[href^="javascript:arrow_down_right"]'), parse_assignment, (err) =>
                wf_callback err, course

          ], (err, course) =>
            course.save (err) =>
              L token.username, "Parsed course [#{course.title}]"
              course_callback err

      async.forEach courses, parse_course, (err) ->
        Account.update _id: token.username,
          updated: Date.now()
          is_new: false
          (err) =>
            cb err, new_assignments: new_assignments

  _authenticated_request: (cookie, resource, callback) ->

    if not cookie
      callback "Authentication error: No session cookie"

    options =
      host: "www.jbha.org"
      method: 'GET'
      path: "/students/#{resource}"
      headers:
        'Cookie': cookie

    req = http.request options, (res) ->
      body = null
      res.on 'data', (chunk) ->
        body += chunk
      res.on 'end', ->
        callback null, cheerio.load(body)

    req.on 'error', (err) ->
      callback err

    req.end()

  _parse_courses: (cookie, callback) ->
    @_authenticated_request cookie, "homework.php", (err, $) ->

      courses = []

      parse_course = (element, fe_callback) ->
        courses.push
          title: $(element).text()
          id: $(element).attr('href').match(/\d+/)[0]
        fe_callback null

      # Any link that has a href containing the 
      # substring ``?course_id=`` in it.
      async.forEach $('a[href*="?course_id="]'), parse_course, (err) ->
        callback courses

  _call_if_truthy: (err, func) ->
    if err
      func err
      return true

  _stats: (callback) ->
    Account
      .find()
      .sort('updated', -1)
      .select('_id', 'updated', 'nickname')
      .run (err, docs) ->
        NUM_SHOWN = 10
        if docs.length < NUM_SHOWN
          showing = docs.length
        else
          showing = NUM_SHOWN
        console.log "Showing most recently active #{String(showing).red} of #{String(docs.length).red} accounts"
        for doc in docs[0..NUM_SHOWN]
          name = doc._id
          nickname = doc.nickname
          date = moment(doc.updated)
          console.log "\n#{name.bold} (#{nickname})"
          console.log date.format("» M/D").yellow + " @ " + date.format("h:mm:ss A").cyan + " (#{date.fromNow().green})"
        callback()