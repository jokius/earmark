SHELL     := /bin/bash

# Личная identity для подписи — в signing.local, он не в гите (шаблон: signing.local.example).
# Без него сборка ad-hoc: работает, но TCC переспрашивает микрофон, системный звук и календари
# после каждой пересборки.
#
# Hardened Runtime включаем только при подписи с Team ID: у ad-hoc подписи его нет, и library
# validation не пустила бы whisper.framework в CLI («different Team IDs», проверено на Release).
# Признак подписи — DEVELOPMENT_TEAM, а не CODE_SIGN_IDENTITY: identity может прийти из окружения
# ("-"), а runtime без Team ID невозможен. В project.yml дефолт NO.
#
# Team намеренно не в project.yml: репозиторий публичный, и с чужим DEVELOPMENT_TEAM сборка
# у постороннего упала бы на «No account for team».
-include signing.local
SIGN_ARGS  = $(if $(DEVELOPMENT_TEAM),CODE_SIGN_IDENTITY="$(or $(CODE_SIGN_IDENTITY),Apple Development)" DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" $(if $(CODE_SIGN_STYLE),CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)",) ENABLE_HARDENED_RUNTIME=YES,)

PROJECT   := Earmark.xcodeproj
SCHEME    := Earmark
CONFIG    ?= Debug
# Свой DerivedData в build/: путь к .app известен заранее, без разбора -showBuildSettings.
DERIVED   := build
APP        = $(DERIVED)/Build/Products/$(CONFIG)/Earmark.app
DEST      := platform=macOS,arch=$(shell uname -m)
SOURCES   := App CLI Sources Tests Package.swift
INSTALLED := /Applications/Earmark.app
CLI_LINK  := $(HOME)/.local/bin/earmark

.DEFAULT_GOAL := build
.PHONY: gen build release install uninstall test fmt fmt-check lint lint-fix check clean run

# xcodegen отрабатывает за десятки миллисекунд, поэтому генерируем всегда: файловая
# зависимость врёт при УДАЛЕНИИ исходника, и проект остался бы со ссылкой на пустоту.
gen:
	@xcodegen generate --quiet

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DEST)' \
	  -derivedDataPath $(DERIVED) -quiet $(SIGN_ARGS) build

release:
	$(MAKE) build CONFIG=Release

# SIGTERM — штатный выход app: очередь ждёт воркер транскрипции до 2 с, чтобы попытка не сгорела.
# Не вышел за 5 с (завис) — SIGKILL: rm -rf под живым процессом оставил бы старый бинарь в памяти.
STOP_APP = pkill -x Earmark 2>/dev/null || true; \
	for i in $$(seq 25); do pgrep -x Earmark >/dev/null || break; sleep 0.2; done; \
	pkill -9 -x Earmark 2>/dev/null || true

# Release в /Applications: оттуда работает login item (SMAppService), а TCC видит app,
# запущенный через LaunchServices. `make install CONFIG=Debug` ставит Debug — с пробами спайков.
# Последний шаг запускает CLI через symlink: так сразу видны и rpath, и library validation.
install: CONFIG := Release
install: build
	$(STOP_APP)
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" /Applications/
	codesign --verify --deep --strict "$(INSTALLED)" && echo "signature valid"
	mkdir -p "$(dir $(CLI_LINK))"
	@if [ -e "$(CLI_LINK)" ] && [ "$$(readlink "$(CLI_LINK)")" != "$(INSTALLED)/Contents/Helpers/earmark" ]; then \
	  echo "refusing to replace $(CLI_LINK): it is not earmark's symlink"; exit 1; fi
	ln -sf "$(INSTALLED)/Contents/Helpers/earmark" "$(CLI_LINK)"
	"$(CLI_LINK)" help > /dev/null && echo "CLI runs"
	@echo "installed: $(INSTALLED), CLI: $(CLI_LINK)"
	open "$(INSTALLED)"

# Symlink удаляем, только если он наш: чужой earmark в ~/.local/bin не трогаем.
uninstall:
	$(STOP_APP)
	rm -rf "$(INSTALLED)"
	if [ "$$(readlink "$(CLI_LINK)")" = "$(INSTALLED)/Contents/Helpers/earmark" ]; then rm -f "$(CLI_LINK)"; fi

# Только пакетные тесты: app-hosted тесты у рекордера значили бы настоящую запись (§3.1 п.4).
test:
	swift test

fmt:
	swift format format --in-place --recursive --parallel $(SOURCES)

fmt-check:
	swift format lint --recursive --parallel --strict $(SOURCES)

lint:
	swiftlint lint --quiet --strict

lint-fix:
	swiftlint lint --fix --quiet
	$(MAKE) fmt

check: fmt-check lint test

clean:
	rm -rf $(PROJECT) $(DERIVED) .build

run: build
	open "$(APP)"

.PHONY: install-skill

# Скилл для агентов (§9.5): симлинк на папку в репо, а не копия, — правка SKILL.md сразу видна
# агентам. Каталоги агентов не создаём: нет ~/.claude — значит, нет и Claude Code.
# ~/.agents/skills читают Codex и universal-агенты. ~/.codex/skills — запасной путь для старого
# Codex и только когда общего каталога нет: иначе Codex покажет скилл дважды (так же решает
# установщик `npx skills`). Чужую папку на месте ссылки не трогаем — её поставили иначе.
install-skill:
	@link() { \
	  if [ -e "$$2" ] && [ ! -L "$$2" ]; then echo "skip: $$2 exists and is not a symlink"; \
	  else ln -sfn "$$1" "$$2" && echo "$$2 -> $$1"; fi; }; \
	src="$(CURDIR)/skills/earmark"; \
	if [ -d "$(HOME)/.claude" ]; then mkdir -p "$(HOME)/.claude/skills"; link "$$src" "$(HOME)/.claude/skills/earmark"; fi; \
	if [ -d "$(HOME)/.agents/skills" ]; then link "$$src" "$(HOME)/.agents/skills/earmark"; \
	elif [ -d "$(HOME)/.codex/skills" ]; then link "$$src" "$(HOME)/.codex/skills/earmark"; fi
