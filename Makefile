APP_NAME     := MDPreviewer
BUILD_DIR    := build
DERIVED      := $(BUILD_DIR)/DerivedData
APP_PATH     := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
INSTALL_PATH := /Applications/$(APP_NAME).app
SAMPLE       ?= $(CURDIR)/Samples/sample.md

.PHONY: all build install uninstall run clean rendercheck webcheck imagecheck datacheck embed

all: run

build:
	xcodegen generate
	xcodebuild \
		-project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		build

install: build
	@# A ordem importa, e na ordem inversa do que parece óbvio:
	@# 1. derruba os daemons e limpa o cache ANTES de copiar, senão o macOS
	@#    reaproveita o binário antigo;
	@# 2. registra a extensão por último, porque o `qlmanage -r` do passo 1
	@#    também limpa o registro — registrar antes não sobrevive a ele.
	pkill -9 -f qlmanage 2>/dev/null || true
	killall -9 quicklookd quicklookd_helper QuickLookUIService 2>/dev/null || true
	rm -rf "$(INSTALL_PATH)"
	qlmanage -r cache >/dev/null 2>&1 || true
	qlmanage -r >/dev/null 2>&1 || true
	cp -R "$(APP_PATH)" "$(INSTALL_PATH)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_PATH)"
	pluginkit -a "$(INSTALL_PATH)/Contents/PlugIns/$(APP_NAME)Extension.appex" >/dev/null 2>&1 || true
	@echo "instalado e registrado em $(INSTALL_PATH)"

uninstall:
	@# Registros do Launch Services aparecem em três lugares: o app instalado,
	@# os apps das pastas de build (o xcodebuild registra o .app que produz a
	@# cada build) e o release antigo. Sem desregistrar os três, o Finder
	@# continua enxergando a extensão depois do .app sumir.
	-@for app in "$(INSTALL_PATH)" "$(APP_PATH)" "$(CURDIR)/build/ReleaseData/Build/Products/Release/$(APP_NAME).app"; do \
		if [ -d "$$app" ]; then \
			pluginkit -r "$$app/Contents/PlugIns/$(APP_NAME)Extension.appex" 2>/dev/null || true; \
			/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$$app" 2>/dev/null || true; \
		fi; \
	done
	pkill -9 -f qlmanage 2>/dev/null || true
	killall -9 quicklookd quicklookd_helper QuickLookUIService 2>/dev/null || true
	rm -rf "$(INSTALL_PATH)"
	qlmanage -r cache >/dev/null 2>&1 || true
	qlmanage -r >/dev/null 2>&1 || true
	@echo "removido. o Finder volta a mostrar .md como texto comum."
	@echo "sobrou no sistema (opcional de apagar):"
	@echo "  ~/Library/Containers/com.mdpreviewer.app.preview  (container com o log de debug)"

run: install
	@echo "abrindo o preview de $(SAMPLE)"
	@qlmanage -p "$(SAMPLE)"

clean:
	rm -rf $(BUILD_DIR)

# O Trace do stub: o renderer é compilado fora da extension, então precisa de
# um substituto para não depender do bundle.
STUB := $(BUILD_DIR)/stub.swift
$(STUB):
	@mkdir -p $(BUILD_DIR)
	@printf 'import Foundation\nenum Trace {\n  static func log(_ m: String) { FileHandle.standardError.write(Data("trace: \\(m)\\n".utf8)) }\n}\n' > $@

# Renderiza um .md e imprime o resultado, sem passar pelo Quick Look. É o
# caminho mais rápido para iterar no layout.
#
# O scanner e o loader entram na lista porque o renderer os usa; sem eles o
# harness compila mas não acha os tipos.
RENDER_SRC := \
	Sources/Extension/NativeMarkdownRenderer.swift \
	Sources/Extension/MarkdownImageScanner.swift \
	Sources/Extension/MarkdownImageLoader.swift

rendercheck: $(STUB)
	@mkdir -p $(BUILD_DIR)
	swiftc -O $(RENDER_SRC) $(STUB) \
		Tests/RenderCheck.swift -o $(BUILD_DIR)/rendercheck
	@$(BUILD_DIR)/rendercheck $(or $(SAMPLE),$(CURDIR)/Samples/sample.md)

# Verifica a montagem do HTML fora do Quick Look, onde o WebKit funciona.
webcheck:
	@mkdir -p $(BUILD_DIR)
	swiftc -O Tests/WebKitCheck.swift -o $(BUILD_DIR)/webkitcheck
	@rm -f "$$TMPDIR/webkitcheck.log"
	@$(BUILD_DIR)/webkitcheck || true
	@cat "$$TMPDIR/webkitcheck.log"

# Confere a barreira de confinamento das imagens e o redimensionamento. Sai com
# código diferente de zero se algum caso falhar, para valer como verificação.
imagecheck: $(STUB)
	@mkdir -p $(BUILD_DIR)
	swiftc -O Sources/Extension/MarkdownImageLoader.swift $(STUB) \
		Tests/ImageAccessProbe.swift -o $(BUILD_DIR)/imagecheck
	@$(BUILD_DIR)/imagecheck $(or $(SAMPLE_DIR),$(CURDIR)/Samples)

# Confere a imagem embutida em data URI, que é o caminho que funciona dentro
# do Quick Look — o sandbox não deixa abrir o .png vizinho.
datacheck: $(STUB)
	@mkdir -p $(BUILD_DIR)
	swiftc -O $(RENDER_SRC) $(STUB) \
		Tests/DataURICheck.swift -o $(BUILD_DIR)/datacheck
	@$(BUILD_DIR)/datacheck $(or $(SAMPLE_DIR),$(CURDIR)/Samples)

# Emite o `![alt](data:...)` de um arquivo, pronto para colar no Markdown.
#
# É a forma de escrever uma imagem que **aparece no Finder**: o Quick Look só
# libera o arquivo em preview, então a imagem precisa viajar dentro do .md.
# O base64 sai partido em linhas de 76 colunas, que é como fica legível.
#
#   make embed SRC=imagens/foto.png ALT="legenda"
#   make embed SRC=a.png ALT=legenda          # imprime só a linha
#   make embed SRC=a.png                      # imprime o base64 puro
embed:
	@test -n "$(SRC)" || { echo "uso: make embed SRC=arquivo.png [ALT=legenda]"; exit 2; }
	@test -f "$(SRC)" || { echo "não achei $(SRC)"; exit 2; }
	@mime=$$(file --brief --mime-type "$(SRC)"); \
	 b64=$$(base64 < "$(SRC)" | tr -d '\n'); \
	 if [ -n "$(ALT)" ]; then \
	  printf '![%s](data:%s;base64,%s)\n' '$(ALT)' "$$mime" "$$b64" \
	    | fold -s -w 76; \
 else \
	  printf 'data:%s;base64,%s\n' "$$mime" "$$b64" | fold -s -w 76; \
 fi
