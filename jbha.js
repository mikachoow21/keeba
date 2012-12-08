// Generated by CoffeeScript 1.4.0
(function() {
  var Account, AccountSchema, Assignment, AssignmentSchema, Course, CourseSchema, Jbha, L, async, cheerio, colors, http, logger, logging, moment, mongo_uri, mongoose, querystring, secrets, _,
    __indexOf = [].indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

  _ = require("underscore");

  async = require("async");

  http = require("http");

  colors = require("colors");

  cheerio = require("cheerio");

  mongoose = require("mongoose");

  moment = require("moment");

  querystring = require("querystring");

  logging = require("./logging");

  secrets = require("./secrets");

  if (process.env.NODE_ENV === "production") {
    mongo_uri = secrets.MONGO_PRODUCTION_URI;
  } else {
    mongo_uri = secrets.MONGO_STAGING_URI;
  }

  mongoose.connect(mongo_uri, function() {});

  String.prototype.capitalize = function() {
    return this.charAt(0).toUpperCase() + this.slice(1);
  };

  AccountSchema = new mongoose.Schema({
    _id: String,
    nickname: String,
    is_new: {
      type: Boolean,
      "default": true
    },
    firstrun: {
      type: Boolean,
      "default": true
    },
    details: {
      type: Boolean,
      "default": true
    },
    migrate: {
      type: Boolean,
      "default": false
    },
    feedback_given: {
      type: Boolean,
      "default": false
    },
    updated: {
      type: Date,
      "default": new Date(0)
    }
  }, {
    strict: true
  });

  Account = mongoose.model('account', AccountSchema);

  CourseSchema = new mongoose.Schema({
    owner: String,
    title: String,
    teacher: String,
    jbha_id: {
      type: String,
      index: {
        unique: false,
        sparse: true
      }
    },
    assignments: [
      {
        type: mongoose.Schema.ObjectId,
        ref: 'assignment'
      }
    ]
  });

  Course = mongoose.model('course', CourseSchema);

  AssignmentSchema = new mongoose.Schema({
    owner: String,
    date: Number,
    title: String,
    details: String,
    jbha_id: {
      type: String,
      index: {
        unique: false,
        sparse: true
      }
    },
    archived: {
      type: Boolean,
      "default": false
    },
    done: {
      type: Boolean,
      "default": false
    }
  });

  Assignment = mongoose.model('assignment', AssignmentSchema);

  logger = new logging.Logger("API");

  Jbha = exports;

  L = function(prefix, message, urgency) {
    if (urgency == null) {
      urgency = "debug";
    }
    return logger[urgency]("" + prefix.underline + " :: " + message);
  };

  exports.silence = function() {
    return L = function() {};
  };

  Jbha.Client = {
    authenticate: function(username, password, cb) {
      var options, post_data, req,
        _this = this;
      username = username.toLowerCase();
      if (username === "acquire") {
        this._call_if_truthy("Invalid login", cb);
      }
      post_data = querystring.stringify({
        Email: "" + username + "@jbha.org",
        Passwd: password,
        Action: "login"
      });
      options = {
        host: "www.jbha.org",
        path: "/students/index.php",
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': post_data.length
        }
      };
      req = http.request(options, function(res) {
        return res.on('end', function() {
          if (res.headers.location === "/students/homework.php") {
            L(username, "Remote authentication succeeded", "info");
            return Account.findOne().where('_id', username).exec(function(err, account_from_db) {
              var account, cookie;
              if (_this._call_if_truthy(err, cb)) {
                return;
              }
              cookie = res.headers['set-cookie'][1].split(';')[0];
              account = account_from_db || new Account();
              res = {
                token: {
                  cookie: cookie,
                  username: username,
                  password: password
                },
                account: account
              };
              if (account_from_db) {
                return cb(null, res);
              } else {
                account.nickname = username.split('.')[0].capitalize();
                account._id = username;
                return account.save(function(err) {
                  if (_this._call_if_truthy(err, cb)) {
                    return;
                  }
                  return cb(null, res);
                });
              }
            });
          } else {
            L(username, "Remote authentication failed", "warn");
            return _this._call_if_truthy("Invalid login", cb);
          }
        });
      });
      req.write(post_data);
      return req.end();
    },
    _create_account: function(username, cb) {
      var account,
        _this = this;
      account = new Account();
      account._id = username;
      account.nickname = "TestAccount";
      return account.save(function(err, doc) {
        if (_this._call_if_truthy(err, cb)) {
          return;
        }
        return cb(null, {
          account: doc,
          token: {
            cookie: "1235TESTCOOKIE54321",
            username: doc._id
          }
        });
      });
    },
    read_settings: function(token, cb) {
      return Account.findOne().where('_id', token.username).select('nickname details is_new firstrun updated migrate feedback_given').exec(cb);
    },
    update_settings: function(token, settings, cb) {
      return Account.update({
        _id: token.username
      }, {
        nickname: settings.nickname,
        details: settings.details,
        firstrun: settings.firstrun,
        migrate: settings.migrate
      }, cb);
    },
    _delete_account: function(token, account, cb) {
      return async.parallel([
        function(callback) {
          return Account.where('_id', account).remove(callback);
        }, function(callback) {
          return Course.where('owner', account).remove(callback);
        }, function(callback) {
          return Assignment.where('owner', account).remove(callback);
        }
      ], cb);
    },
    migrate: function(token, nuke, cb) {
      var finish;
      finish = function() {
        return Account.update({
          _id: token.username
        }, {
          migrate: false
        }, cb);
      };
      if (nuke) {
        return async.parallel([
          function(callback) {
            return Course.where('owner', token.username).remove(callback);
          }, function(callback) {
            return Assignment.where('owner', token.username).remove(callback);
          }
        ], finish);
      } else {
        return finish();
      }
    },
    by_course: function(token, cb) {
      var _this = this;
      return Course.where('owner', token.username).populate('assignments', 'title archived details date done jbha_id').select('-owner -jbha_id').exec(function(err, courses) {
        _this._call_if_truthy(err, cb);
        return cb(err, courses);
      });
    },
    create_assignment: function(token, data, cb) {
      return async.waterfall([
        function(wf_callback) {
          return Course.findById(data.course).exec(wf_callback);
        }, function(course, wf_callback) {
          var assignment;
          assignment = new Assignment();
          assignment.owner = token.username;
          assignment.title = data.title;
          assignment.date = data.date;
          assignment.details = data.details;
          return assignment.save(function(err) {
            return wf_callback(err, course, assignment);
          });
        }, function(course, assignment, wf_callback) {
          course.assignments.addToSet(assignment);
          return course.save(function(err) {
            return wf_callback(err, course, assignment);
          });
        }
      ], function(err, course, assignment) {
        return cb(err, course, assignment);
      });
    },
    update_assignment: function(token, assignment, cb) {
      return async.waterfall([
        function(wf_callback) {
          return Course.update({
            owner: token.username,
            assignments: assignment._id
          }, {
            $pull: {
              assignments: assignment._id
            }
          }, {}, function(err) {
            return wf_callback();
          });
        }, function(wf_callback) {
          return Course.findOne().where('owner', token.username).where('_id', assignment.course).exec(wf_callback);
        }, function(course, wf_callback) {
          course.assignments.addToSet(assignment._id);
          return course.save(wf_callback);
        }
      ], function(err) {
        return Assignment.update({
          owner: token.username,
          _id: assignment._id
        }, {
          title: assignment.title,
          date: assignment.date,
          details: assignment.details,
          done: assignment.done,
          archived: assignment.archived
        }, {}, cb);
      });
    },
    delete_assignment: function(token, assignment, cb) {
      return Assignment.where('owner', token.username).where('_id', assignment._id).remove(cb);
    },
    create_course: function(token, data, cb) {
      var course;
      course = new Course();
      course.owner = token.username;
      course.title = data.title;
      course.teacher = data.teacher;
      return course.save(cb);
    },
    update_course: function(token, course, cb) {
      return Course.update({
        owner: token.username,
        _id: course._id
      }, {
        title: course.title,
        teacher: course.teacher
      }, function(err, numAffected, raw) {
        return cb(err);
      });
    },
    delete_course: function(token, course, cb) {
      return Course.where('owner', token.username).where('_id', course._id).remove(cb);
    },
    create_feedback: function(token, message, cb) {
      var feedback;
      feedback = new Feedback();
      feedback._id = token.username;
      feedback.message = message;
      return feedback.save(function(err) {
        if (err) {
          return cb(err);
        }
        return Account.update({
          _id: token.username
        }, {
          feedback_given: true
        }, function(err) {
          if (err) {
            return cb(err);
          }
          return cb(null);
        });
      });
    },
    read_feedbacks: function(cb) {
      return Feedback.find().exec(function(err, feedbacks) {
        if (err) {
          return cb(err.err);
        } else {
          return cb(null, feedbacks);
        }
      });
    },
    refresh: function(token, options, cb) {
      var _this = this;
      return this._parse_courses(token, function(new_token, courses) {
        var new_assignments, parse_course;
        token = new_token;
        new_assignments = 0;
        parse_course = function(course_data, course_callback) {
          return _this._authenticated_request(token, "course-detail.php?course_id=" + course_data.id, function(err, new_token, $) {
            token = new_token;
            return async.waterfall([
              function(wf_callback) {
                return Course.findOne().where('owner', token.username).where('jbha_id', course_data.id).populate('assignments').exec(wf_callback);
              }, function(course_from_db, wf_callback) {
                var course;
                if (!course_from_db) {
                  course = new Course();
                  course.owner = token.username;
                  course.title = course_data.title;
                  course.jbha_id = course_data.id;
                  course.teacher = $("h1.normal").text().split(":").slice(0)[0];
                } else {
                  course = course_from_db;
                }
                return wf_callback(null, course);
              }, function(course, wf_callback) {
                var parse_assignment;
                parse_assignment = function(element, assignment_callback) {
                  var assignment, assignment_date, assignment_details, assignment_from_db, assignment_id, assignment_title, moved, regex, regexes, splits, text_blob, _i, _len;
                  text_blob = $(element).text();
                  if (text_blob.match(/Due \w{3} \d{1,2}\, \d{4}:/)) {
                    assignment_id = $(element).attr('href').match(/\d+/)[0];
                    splits = text_blob.split(":");
                    assignment_title = splits.slice(1)[0].trim();
                    assignment_date = moment.utc(splits.slice(0, 1)[0], "[Due] MMM DD, YYYY").valueOf();
                    assignment_details = $("#toggle-cont-" + assignment_id).html();
                    if ($("#toggle-cont-" + assignment_id).text()) {
                      regexes = [/\<h\d{1}\>/gi, /\<\/h\d{1}\>/gi, /style="(.*?)"/gi];
                      for (_i = 0, _len = regexes.length; _i < _len; _i++) {
                        regex = regexes[_i];
                        assignment_details = assignment_details.replace(regex, "");
                      }
                      assignment_details = assignment_details.replace(/href="\/(.*?)"/, 'href="http://www.jbha.org/$1"');
                    } else {
                      assignment_details = null;
                    }
                    assignment_from_db = _.find(course.assignments, function(assignment) {
                      if (assignment.jbha_id === assignment_id) {
                        return true;
                      }
                    });
                    if (assignment_from_db) {
                      moved = assignment_from_db.date.valueOf() !== assignment_date && assignment_from_db.title !== assignment_title;
                      if (!moved) {
                        assignment_callback(null);
                        return;
                      }
                    }
                    assignment = new Assignment();
                    assignment.owner = token.username;
                    assignment.title = assignment_title;
                    assignment.jbha_id = assignment_id;
                    assignment.details = assignment_details;
                    assignment.date = assignment_date;
                    course.assignments.push(assignment);
                    new_assignments++;
                    if (options && options.archive_if_old) {
                      if (assignment_date < Date.now()) {
                        assignment.done = true;
                        assignment.archived = true;
                      }
                    }
                    return assignment.save(function(err) {
                      if (moved) {
                        L(token.username, "Create-by-move detected on assignment with jbha_id " + assignment_id + "!", 'warn');
                        assignment_from_db.jbha_id += "-" + assignment_from_db._id;
                        return assignment_from_db.save(function(err) {
                          return assignment_callback(err);
                        });
                      } else {
                        return assignment_callback(err);
                      }
                    });
                  } else {
                    return assignment_callback(err);
                  }
                };
                return async.forEach($('a[href^="javascript:arrow_down_right"]'), parse_assignment, function(err) {
                  return wf_callback(err, course);
                });
              }
            ], function(err, course) {
              return course.save(function(err) {
                L(token.username, "Parsed course [" + course.title + "]");
                return course_callback(err);
              });
            });
          });
        };
        return async.forEach(courses, parse_course, function(err) {
          var _this = this;
          return Account.update({
            _id: token.username
          }, {
            updated: Date.now(),
            is_new: false
          }, function(err) {
            return cb(err, token, {
              new_assignments: new_assignments
            });
          });
        });
      });
    },
    _authenticated_request: function(token, resource, callback) {
      var cookie, options, req,
        _this = this;
      cookie = token.cookie;
      if (!cookie) {
        callback("Authentication error: No session cookie");
      }
      options = {
        host: "www.jbha.org",
        method: 'GET',
        path: "/students/" + resource,
        headers: {
          'Cookie': cookie
        }
      };
      req = http.request(options, function(res) {
        var body;
        body = null;
        res.on('data', function(chunk) {
          return body += chunk;
        });
        return res.on('end', function() {
          var $;
          $ = cheerio.load(body);
          if ($('a[href="/students/?Action=logout"]').length === 0) {
            L(token.username, "Session expired; re-authenticating", "warn");
            return _this.authenticate(token.username, token.password, function(err, res) {
              return _this._authenticated_request(res.token, resource, callback);
            });
          } else {
            return callback(null, token, $);
          }
        });
      });
      req.on('error', function(err) {
        return callback(err);
      });
      return req.end();
    },
    _parse_courses: function(token, callback) {
      return this._authenticated_request(token, "homework.php", function(err, new_token, $) {
        var blacklist, courses, parse_course;
        token = new_token;
        courses = [];
        blacklist = ['433', '665'];
        parse_course = function(element, fe_callback) {
          var course_id;
          course_id = $(element).attr('href').match(/\d+/)[0];
          if (__indexOf.call(blacklist, course_id) < 0) {
            courses.push({
              title: $(element).text(),
              id: course_id
            });
          }
          return fe_callback(null);
        };
        return async.forEach($('a[href*="?course_id="]'), parse_course, function(err) {
          return callback(token, courses);
        });
      });
    },
    _call_if_truthy: function(err, func) {
      if (err) {
        func(err);
        return true;
      }
    },
    _migrationize: function(date, callback) {
      var _this = this;
      return Account.update({
        updated: {
          $lt: moment(date).toDate()
        }
      }, {
        migrate: true
      }, {
        multi: true
      }, function(err, numAffected) {
        if (_this._call_if_truthy(err, callback)) {
          return;
        }
        return callback(null, numAffected);
      });
    },
    _stats: function(num_shown, callback) {
      if (num_shown == null) {
        num_shown = Infinity;
      }
      return Account.find().sort('-updated').select('_id updated nickname').exec(function(err, docs) {
        var date, doc, name, nickname, showing, _i, _len, _ref;
        if (docs.length < num_shown) {
          showing = docs.length;
        } else {
          showing = num_shown;
        }
        console.log("Showing most recently active " + (String(showing).red) + " of " + (String(docs.length).red) + " accounts");
        _ref = docs.slice(1, +num_shown + 1 || 9e9);
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          doc = _ref[_i];
          name = doc._id;
          nickname = doc.nickname;
          date = moment(doc.updated);
          console.log("\n" + name.bold + " (" + nickname + ")");
          console.log(date.format("» M/D").yellow + " @ " + date.format("h:mm:ss A").cyan + (" (" + (date.fromNow().green) + ")"));
        }
        return callback();
      });
    }
  };

}).call(this);
