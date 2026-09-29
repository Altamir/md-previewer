---
title: Sample
tags: [demo, quicklook]
---

# Preview de Markdown

Este arquivo exercita o que a extensão renderiza.

## Texto

**Negrito**, *itálico*, ~~tachado~~, `código inline` e um [link](https://example.com).

## Listas

- Item de lista
- Item com código: `npm run dev`
- [x] Tarefa concluída
- [ ] Tarefa pendente

1. Primeiro
2. Segundo
3. Terceiro

## Tabela

| Recurso | Status | Observação |
|---------|:------:|----------:|
| Headings | ok | GFM |
| Tabelas | ok | GFM |
| Realce | ok | highlight.js |

## Código

```swift
struct Preview {
    let title: String
    var body: some View { Text(title) }
}
```

```python
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

## Citação e imagens

> Markdown renderizado direto no Finder, com barra de espaço.

![Imagem relativa](sample-assets/preview.png)

![Imagem que não existe](sample-assets/ausente.png)

---

Feito.
