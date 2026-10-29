APP_ID   := io.github.ltspice_wine.LTspice
MANIFEST := $(APP_ID).yml
BUILDER  := flatpak run --filesystem=$(CURDIR) org.flatpak.Builder

.PHONY: build install bundle run lint clean

build:
	$(BUILDER) --user --force-clean --install-deps-from=flathub --repo=repo build-dir $(MANIFEST)

install:
	$(BUILDER) --user --force-clean --install-deps-from=flathub --repo=repo --install build-dir $(MANIFEST)

bundle: build
	flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo repo LTspice.flatpak $(APP_ID)

run:
	flatpak run $(APP_ID)

lint:
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest $(MANIFEST)
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream data/$(APP_ID).metainfo.xml

clean:
	rm -rf build-dir repo .flatpak-builder LTspice.flatpak
