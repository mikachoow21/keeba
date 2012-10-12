REPORTER = list

serve:
	@node server.js

docs: clean-docs
	@./node_modules/docco/bin/docco *.coffee

clean-docs:
	@rm -rf docs

test:
	@./node_modules/mocha/bin/mocha --timeout 15000 \
	 --compilers coffee:coffee-script \
	 --reporter $(REPORTER)

build:
	@coffee --compile *.coffee && coffeelint *.coffee

clean:
	@rm *.js

.PHONY: build clean serve test docs clean-docs