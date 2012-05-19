var KeebaRouter = Backbone.Router.extend({

  current_view: null,

  routes: {
    "":                  "home",
    "courses/:id":       "course",
    "dates/:name":       "date",
  },

  home: function () {
    $("#content").html(home_template());
  },

  course: function (id) {
    var course = courses.get(id);

    if (_.isUndefined(course)) {
      return this.navigate ('', true);
    }

    if (!_.isNull(this.current_view)) {
      this.current_view.remove();
    }

    this.current_view = new SectionView({model: course});

    $("#content").html(this.current_view.render().el);
    this.trigger("highlight");
  },

  date: function (link_name) {
    var date = DATE_MAP[link_name];

    if (_.isUndefined(date)) {
      return this.navigate ('', true);
    }

    if (!_.isNull(this.current_view)) {
      this.current_view.remove();
    }

    this.current_view = new DatesView({
      template: dates_template,
      title: date.name,
      range: {start: date.start, end: date.end}
    });

    $("#content").html(this.current_view.render().el);
    this.trigger("highlight");
  }
});