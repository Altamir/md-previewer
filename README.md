# MD Previewer

Extensão de Quick Look que renderiza Markdown no Finder. Selecione um `.md` e
pressione **espaço** para ver o conteúdo formatado em vez do texto cru.

```
make run                       # compila, instala e abre o preview de Samples/sample.md
make run SAMPLE=/caminho.md    # abre outro arquivo
```

## Instalação

Precisa de macOS 14 ou superior, Xcode e o
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen
```

Depois:

```
make run
```

O que o `make run` faz, em ordem:

1. `xcodegen generate` cria o `.xcodeproj` a partir do `project.yml`
2. `xcodebuild` compila em Debug
3. derruba o `quicklookd` e limpa o cache do Quick Look
4. copia o `MDPreviewer.app` para `/Applications`
5. registra a extensão (`lsregister -f` e `pluginkit -a`)
6. abre a janela de preview do `Samples/sample.md`

Dois passos dessa ordem não são arbitrários. O cache precisa ser limpo **antes**
de copiar, senão o macOS reaproveita o binário antigo. E o registro precisa
acontecer **depois** do `qlmanage -r`, porque o reset também apaga o registro —
se você registrar antes, ele não sobrevive. Note ainda que o `lsregister -f`
sozinho não registra a extensão; é o `pluginkit -a` que efetivamente o faz.

Se preferir compilar e instalar separados:

```
make build      # só compila, em build/DerivedData
make install    # instala o que foi compilado e limpa o cache
```

Para instalar sem barra de espaço, basta abrir qualquer `.md` e apertar
**espaço** — não há configuração para ativar.

## Remoção

```
make uninstall
```

Apaga o `MDPreviewer.app` de `/Applications`, desregistra a extensão e limpa o
cache. O Finder volta a mostrar o `.md` como texto comum.

Há uma pegadinha aqui que vale registrar: o registro da extensão existe em
**três lugares** — o app instalado, o app na pasta de build em Debug e o da
pasta de build em Release. O `xcodebuild` registra cada `.app` que produz, e
esse registro sobrevive a apagar `/Applications`. Se você desinstalar só o
.app do `/Applications`, o Finder continua enxergando a extensão e pode abrir
um preview em branco. Por isso o `make uninstall` desregistra os três.

Para remover na mão, o equivalente é:

```
APP=/Applications/MDPreviewer.app
pluginkit -r "$APP/Contents/PlugIns/MDPreviewerExtension.appex"
lsregister -u "$APP"
rm -rf "$APP"
qlmanage -r cache && qlmanage -r
```

O `qlmanage -r` importa mesmo depois de o `.app` sumir, porque o macOS guarda a
referência à extensão por um tempo. Se você fez build em Debug ou Release, repita
o `pluginkit -r` e o `lsregister -u` para os apps nessas pastas.

Fica no sistema, se quiser apagar também:

- **Preferências do Sistema → General → Login Items & Extensions**, na aba
  *Extensions*, deve aparecer "MD Previewer"
- o container da extensão, que guarda o log de debug:
  `~/Library/Containers/com.mdpreviewer.app.preview`

Verificar se está limpo:

```
pluginkit -m -p com.apple.quicklook.preview | grep mdpreviewer   # não deve retornar nada
```

## O que ele renderiza

Headings, negrito, itálico, tachado, listas ordenadas e não ordenadas, listas
de tarefa, tabelas, blockquote, trechos de código, imagens e links. O front
matter YAML do topo do arquivo é descartado em vez de virar texto.

O tema acompanha a aparência do sistema (claro/escuro) automaticamente.

## Como funciona

```
Finder (espaço em foo.md)
   └─ QuickLook → PreviewViewController
        ├─ MarkdownDocument        lê o arquivo (security-scoped) e remove o front matter
        ├─ NativeMarkdownRenderer  PresentationIntent → NSTextView
        │    ├─ MarkdownImageScanner  ![...](...) no texto-fonte
        │    └─ MarkdownImageLoader  resolve, confina e reduz à coluna
        └─ WKWebView              motor alternativo, ver "WebKit" abaixo
```

São dois targets:

| Target | Papel |
| --- | --- |
| `MDPreviewer` | Container sem janela (`LSUIElement`). Existe só porque o macOS só registra uma extensão Quick Look embarcada em um `.app`. |
| `MDPreviewerExtension` | A preview em si, ponto de extensão `com.apple.quicklook.preview`. |

O projeto Xcode é gerado a partir de `project.yml` com [XcodeGen](https://github.com/yonaskolb/XcodeGen), então o `.xcodeproj` não é versionado.

## WebKit

O preview tem dois motores de renderização, escolhidos em
`PreviewViewController.Engine`:

- `.native` (padrão) — parser de Markdown da própria Apple num `NSTextView`.
  Sem WebKit, sem JavaScript, sem dependências externas. Cobre GFM completo e
  aparece instantaneamente. As imagens relativas são desenhadas, mas dependem
  de acesso ao disco que o Quick Look não concede — ver "Imagens relativas".
- `.web` — `WKWebView` com [marked](https://github.com/markedjs/marked),
  [DOMPurify](https://github.com/cure53/DOMPurify) e
  [highlight.js](https://highlightjs.org). Dá o visual idêntico ao GitHub, com
  realce de sintaxe colorido e as imagens relativas carregando pelo esquema
  `mdasset://`.

### O renderer nativo

O parser da Apple não entrega estilo pronto. Com
`interpretedSyntax: .full` ele devolve runs anotadas com `PresentationIntent`
— mas **sem fonte, sem cor e sem nenhuma quebra de linha entre blocos**: o
texto chega todo emendado (`"Título H1Parágrafo com negrito"`). O
`NativeMarkdownRenderer` percorre esses intents e reconstrói a apresentação.

Duas coisas que valem saber, porque não são óbvias:

- **`PresentationIntent.components` é a cadeia de aninhamento, não o bloco.**
  Um item de lista vem como `paragraph > listItem 1 > unorderedList`; uma
  célula de tabela como `tableCell 0 > tableRow 1 > table [colunas]`. O tipo
  do documento é o **primeiro** componente e o contexto é o resto.
- **`InlinePresentationIntent` é um `OptionSet` sem membros nomeados.** Os
  valores medidos no parser são 1 itálico, 2 negrito, 4 código, 32 tachado —
  link não passa por aí, vem em `run.link`.

Tabelas usam tabulações com `tabStops` posicionados em pontos, não espaços de
padding. Padding manual contaria caracteres e desalinharia em qualquer célula
com acento — `Observação` tem 10 caracteres e ocupa menos espaço que
`Highlight` com 12, o que empurra a coluna vizinha.

**O `.web` não funciona nesta máquina.** A `WKWebView` é criada, entra na
janela e recebe o HTML, mas o processo de conteúdo do WebKit não executa o
JavaScript: nenhum `didFinish`, nenhum callback, nem com uma página mínima de
1 KB. Fora do Quick Look o mesmo HTML renderiza sem problema
(`make webcheck` comprova), então é o WebKit dentro da extensão que não sobe —
não o código do preview. Já foram tentados, sem efeito: as capabilities
`com.apple.security.cs.allow-jit` e `allow-unsigned-executable-memory` no
sandbox, o build em Release, e o HTML todo embutido em vez de lido de disco.

Se você testar em outra máquina e o WebKit funcionar, troque `Engine.current`
para `.web` em [PreviewViewController.swift](Sources/Extension/PreviewViewController.swift)
e ganhe o visual do GitHub de graça. Enquanto isso, o modo nativo cobre o
essencial.

Quando o motor web não confirma o render, o preview cai para o texto do
Markdown em vez de deixar a janela em branco.

## Imagens

Há duas formas de escrever uma imagem, e elas se comportam de jeitos bem
diferentes no Finder:

| No Markdown | No preview do Finder |
| --- | --- |
| `![alt](data:image/png;base64,…)` | **abre** |
| `![alt](sample-assets/preview.png)` | mostra o alt |

A segunda não abre porque o poder do Quick Look é sobre o arquivo em preview e
**só** sobre ele — e isso não é contornável de dentro da extensão. A primeira
funciona porque os bytes estão dentro do próprio `.md`, que é justamente o
arquivo que o sandbox libera. Ver "Por que o caminho relativo não abre" abaixo.

O caminho relativo continua sendo renderizado de todas as formas: numa
instalação onde o sistema conceda acesso ao diretório, ou fora do Quick Look,
ele carrega normalmente. `Samples/sample-embedded.md` mostra os dois lado a
lado.

### Por que o parser da Apple não entrega imagens

Medido no parser com `interpretedSyntax: .full`,
`![alt](dir/arquivo.png)` volta como um parágrafo qualquer cujo texto é só o
alt. **O caminho some**: não há `run.link`, não há marca de imagem, não há
nada que o renderer pudesse estilizar. Por isso o `MarkdownImageScanner`
localiza a sintaxe no texto-fonte antes do parser, troca cada `![...](...)` por
um marcador opaco, e o `NativeMarkdownRenderer` troca o marcador por um
`NSTextAttachment`. Fora de bloco de código — dentro de ``` o `![…](…)` é só
texto e não vira imagem.

O base64 partido em linhas, que é como uma imagem embutida fica legível num
Markdown escrito à mão, é remontado pelo scanner: as quebras são removidas
porque o texto que o parser recebe em cima é um bloco só, e uma quebra no meio
faria o resto do arquivo ser lido como outro parágrafo.

### Por que o caminho relativo não abre

Isto foi medido dentro da extensão, e o log registra cada tentativa:

| Tentativa | Resultado |
| --- | --- |
| `startAccessing…` no `.png` vizinho | `false`, leitura negada |
| Leitura **dentro** da janela de acesso ao `.md` | `existe=true legivel=false` |
| `bookmarkData(options: .withSecurityScope)` no vizinho | falha — criar o bookmark já exige o acesso que se quer conquistar |
| `startAccessing…` no **diretório** do `.md` | `false` |
| `QLSupportedImageContentTypes` no bundle | não amplia o poder |
| `com.apple.security.app-sandbox = false` | a extensão **nem carrega** (Quick Look exige sandbox) |

O `previewItemURL` autoriza o arquivo em preview e nada além dele. Por isso a
solução é a imagem **viajar dentro do Markdown**, em data URI — nenhum acesso a
disco é preciso. Para embutir uma imagem:

```
make embed SRC=imagens/foto.png ALT="legenda"
```

### Confinamento

Um caminho relativo só é aceito dentro do diretório do próprio Markdown,
depois de `standardizedFileURL` + `resolvingSymlinksInPath` — o mesmo do
esquema `mdasset://` do motor web. `../`, caminho absoluto, symlink para fora e
`https:` são rejeitados. Um data URI não toca o disco, então a regra não se
aplica a ele.

```
make imagecheck    # 14 casos de confinamento + proporção do redimensionamento
make datacheck     # o caminho do data URI, ponta a ponta
```

Ambos saem com código diferente de zero se algum caso falhar.

## Segurança

O `marked` renderiza HTML embutido por padrão, então tudo passa pelo
DOMPurify antes de ir para a página. Sem isso, um `.md` vindo de um repositório
qualquer executaria script dentro da webview.

## Requisitos

macOS 14 ou superior e Xcode. O XcodeGen já está listado na
[instalação](#instalação).

A extensão é assinada ad-hoc, o que basta para uso local e não para
distribuição.

## Layout

```
project.yml                  definição dos dois targets (XcodeGen)
Makefile                     build, install, uninstall, run, rendercheck,
                             webcheck, imagecheck
Sources/App/                 container sem janela
Sources/Extension/
  PreviewViewController.swift    monta a view, escolhe o motor
  MarkdownDocument.swift         leitura segura + remoção de front matter
  NativeMarkdownRenderer.swift   PresentationIntent → NSTextView
  MarkdownImageScanner.swift     localiza ![...](...) no texto-fonte
  MarkdownImageLoader.swift      resolve o caminho, confina e redimensiona
  AssetSchemeHandler.swift       esquema mdasset:// para o motor web
  Trace.swift                    log em arquivo do container
Resources/
  preview.html                  template com placeholders
  theme.css                     tema claro/escuro
  vendor/                       marked, DOMPurify, highlight.js
Samples/sample.md           exercita todos os recursos
Tests/RenderCheck.swift     renderiza um .md e imprime o resultado
Tests/WebKitCheck.swift     renderiza o HTML fora do Quick Look
Tests/ImageAccessProbe.swift confere o confinamento e o redimensionamento
```

## Depuração

A extensão roda dentro do `quicklookd`, sem console. O log vai para o arquivo:

```
tail -f ~/Library/Containers/com.mdpreviewer.app.preview/Data/tmp/mdpreviewer.log
```

O `Trace.buildTag` muda a cada build válido — se o valor no log não for o
esperado, o macOS carregou um bundle antigo. `make install` já derruba o
`quicklookd` e limpa o cache do Quick Look, que é a causa mais comum de "minha
mudança não aparece".

Para conferir o layout sem passar pelo Quick Look — o jeito mais rápido de
iterar no renderer:

```
make rendercheck
```

Para validar o `preview.html` (motor WebKit) fora do Quick Look:

```
make webcheck
```
