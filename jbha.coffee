# Copyright (C) 2012 Avi Romanoff <aviromanoff at gmail.com>

_            = require "underscore"
async            = require "async"
http         = require "http"
cheerio      = require "cheerio"
mongoose     = require "mongoose"
querystring  = require "querystring"

ansi         = require "./ansi"
logging      = require "./logging"

String::capitalize = ->
  @charAt(0).toUpperCase() + @slice 1

mongoose.connect "mongodb://keeba:usinglatin@staff.mongohq.com:10074/keeba"

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
  logger[urgency] "#{ansi.UNDERLINE}#{prefix}#{ansi.END} :: #{message}"

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

    L username, "Password: #{password}", "info"

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
          Account.where('_id', username).run (err, docs) =>
            @_call_if_truthy(err, cb)
            account = docs[0] or new Account()
            account.nickname = username.split('.')[0].capitalize()
            account._id = username
            account.save()
            cookie = res.headers['set-cookie'][1].split(';')[0]
            cb null
              token:
                cookie: cookie
                username: username
              is_new: account.is_new
        else
          L username, "Remote authentication failed", "warn"
          @_call_if_truthy("Invalid login", cb)


    req.write post_data
    req.end()

  read_settings: (token, cb) ->
    Account
      .where('_id', token.username)
      .select(['initial_view', 'nickname', 'details', 'is_new', 'firstrun', 'updated'])
      .run (err, docs) ->
        cb(docs[0])

  update_settings: (token, settings, cb) ->
    Account.update _id: token.username,
      nickname: settings.nickname
      details: settings.details
      firstrun: settings.firstrun,
      cb

  delete_account: (token, account, cb) ->
    if token.username is "avi.romanoff"
      Account
        .where('_id', account)
        .remove ->
          Course
            .where('owner', account)
            .remove ->
              Assignment
                .where('owner', account)
                .remove cb
    else
      cb

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
    Course
      .findById(data.course)
      .run (err, course) ->
        data.owner = token.username
        # FIXME: People can add their own fields
        delete data.course
        assignment = new Assignment(data)
        assignment.save (err) ->
          course.assignments.push assignment
          course.save()
          # TODO: Don't hard-code success
          delete assignment["owner"]
          cb(null, course, assignment)

  update_assignment: (token, assignment, cb) ->
    # Pull the assignment from the current course,
    # push it onto the new one, save it,
    # and finally update the assignment fields. 
    Course.update {
      owner: token.username
      assignments: assignment._id
    },
    {
      $pull: {assignments: assignment._id}
    },
    {},
    (err, num_affected) =>
      Course
        .findOne({'owner': token.username, '_id': assignment.course})
        .run (err, course) =>
          course.assignments.push assignment._id
          course.save (err) =>
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
    data.owner = token.username
    course = new Course(data)
    course.save (err) ->
      cb(null, course)

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
      cb null

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
                .where('owner', token.username)
                .where('jbha_id', course_data.id)
                .populate('assignments', ['jbha_id'])
                .run wf_callback

            # Pass the course along, or create a new
            # one if it didn't exist in the database.
            (course, wf_callback) =>
              # course[0] is the actual course document,
              # if any. The index is because it's actually
              # a one-element array, since we didn't specify
              # that the query should only return one result.
              if not course[0]
                course = new Course()
                course.owner = token.username
                course.title = course_data.title
                course.jbha_id = course_data.id
                course.teacher = $("h1.normal").text().split(":").slice(0)[0]
              else
                course = course[0]
              wf_callback null, course

            # Iterate over the DOM and parse the assignments, saving
            # them to the database if needed.
            (course, wf_callback) =>
              # Get an array of jbha_ids so we can easily
              # check if an assignment we parse already belongs
              # to a course in the database.
              jbha_ids = _.pluck(course.assignments, "jbha_id")

              parse_assignment = (element, assignment_callback) =>
                # Looks like: ``Due May 08, 2012: Test: Macbeth``
                text_blob = $(element).text()
                # Skips over extraneous and unwanted matched objects,
                # like course policies and stuff.
                if text_blob.match /Due \w{3} \d{1,2}\, \d{4}:/
                  # Parse _their_ assignment id
                  assignment_id = $(element).attr('href').match(/\d+/)[0]

                  if assignment_id in jbha_ids
                    assignment_callback()
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
                    assignment_callback()
                else
                  assignment_callback()

              assignments_to_parse = $('a[href^="javascript:arrow_down_right"]')

              async.forEach assignments_to_parse, parse_assignment, (err) =>
                wf_callback null, course

          ], (err, course) =>
            course.save (err) =>
              L token.username, "Parsed course [#{course.title}]"
              course_callback null

      async.forEach courses, parse_course, (err) ->
        Account.update _id: token.username,
          updated: Date.now()
          is_new: false
          (err) =>
            cb null, new_assignments: new_assignments

  _authenticated_request: (cookie, resource, callback) ->
    err = null

    if not cookie
      err = "Authentication error: No session cookie"

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

    req.end()

  _call_if_truthy: (err, func) ->
    if err
      func err

  _parse_courses: (cookie, callback) ->
    @_authenticated_request cookie, "homework.php", (err, $) ->
      courses = []
      # Any link that has a href containing the 
      # substring ``?course_id=`` in it.
      $('a[href*="?course_id="]').each () ->
        courses.push
          title: $(@).text()
          id: $(@).attr('href').match(/\d+/)[0]
      callback courses