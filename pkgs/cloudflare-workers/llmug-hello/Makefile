.PHONY: all
all: build

.PHONY: clean
clean:
	rm -rf dist

.PHONY: build
build: clean
	mkdir -p dist
	cp index.html favicon.ico dist/
	cp -r css js icons dist/

.PHONY: deploy
deploy: build
	wrangler2 deploy --assets dist

.PHONY: lint
lint:
	biome check

.PHONY: fix
fix:
	biome check --write
