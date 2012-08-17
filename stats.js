// Generated by CoffeeScript 1.3.3
(function() {
  var argv, jbha;

  argv = require("optimist").usage("Show recently active users.\nUsage: $0 -n [num]").alias('n', 'num').demand('n').describe('n', "Number of recently active users to show").argv;

  jbha = require("./jbha");

  jbha.Client._stats(argv.n, function(err) {
    return process.exit();
  });

}).call(this);