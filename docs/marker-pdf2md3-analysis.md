# Marker: PDF/Document to Markdown Converter

A deep-learning powered document conversion library that converts PDFs, images, and office documents to Markdown, JSON, HTML, or chunks.

**Repository:** `marker/` (submodule)

---

## Overview

Marker uses a multi-stage pipeline to convert documents:

```
Input (PDF, DOCX, PPTX, EPUB, HTML, Images)
    ↓
Provider (format detection + text/image extraction)
    ↓
Builders (layout detection, line extraction, OCR)
    ↓
Processors (23+ content processors)
    ↓
Renderer (Markdown, HTML, JSON, Chunks)
    ↓
Output (files + metadata + images)
```

---

## Supported Input Formats

| Format | Extension | Provider |
|--------|-----------|----------|
| PDF | `.pdf` | `PdfProvider` |
| Word | `.docx` | `DocumentProvider` |
| Excel | `.xlsx` | `SpreadSheetProvider` |
| PowerPoint | `.pptx` | `PowerPointProvider` |
| EPUB | `.epub` | `EpubProvider` |
| HTML | `.html` | `HTMLProvider` |
| Images | `.png, .jpg, .gif` | `ImageProvider` |

Non-PDF formats are converted to intermediate PDF first, then processed.

---

## Output Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| **Markdown** | `.md` | Default. Clean markdown with tables, math, images |
| **HTML** | `.html` | Semantic HTML with optional block IDs |
| **JSON** | `.json` | Nested tree structure preserving hierarchy |
| **Chunks** | `.json` | Flattened blocks for RAG/indexing |

---

## Architecture

### 1. Providers (`marker/providers/`)

Extract raw data from input files:
- `PdfProvider`: Uses `pdftext` for text, `pypdfium2` for images
- Other providers convert to PDF first, then inherit `PdfProvider`

### 2. Builders (`marker/builders/`)

Build document structure:

| Builder | Purpose |
|---------|---------|
| `DocumentBuilder` | Orchestrates pipeline, creates PageGroups |
| `LayoutBuilder` | Surya model for block detection (Text, Table, Figure) |
| `LineBuilder` | Decides PDF text vs OCR per page |
| `OcrBuilder` | Surya recognition for scanned pages |
| `StructureBuilder` | Groups captions, lists, footnotes |

**Two-resolution strategy:**
- Lowres (96 DPI): Layout and line detection
- Highres (192 DPI): OCR character recognition

### 3. Processors (`marker/processors/`)

23+ processors transform the document:

**Content Recognition:**
- `TableProcessor` - Cell detection, text assignment
- `EquationProcessor` - LaTeX recognition
- `CodeProcessor` - Indentation reconstruction
- `ListProcessor` - Nested list hierarchy
- `SectionHeaderProcessor` - Heading levels via K-Means clustering

**Cleanup:**
- `IgnoreTextProcessor` - Remove repeated headers/footers
- `LineNumbersProcessor` - Strip line numbers
- `BlankPageProcessor` - Detect empty pages

**LLM-Enhanced (optional):**
- `LLMTableProcessor` - Table correction
- `LLMEquationProcessor` - Math improvement
- `LLMImageDescriptionProcessor` - Alt-text generation

### 4. Renderers (`marker/renderers/`)

| Renderer | Output |
|----------|--------|
| `MarkdownRenderer` | `.md` with tables, math delimiters |
| `HTMLRenderer` | Semantic HTML, image extraction |
| `JSONRenderer` | Nested block tree |
| `ChunkRenderer` | Flattened blocks with coordinates |

---

## Usage

### CLI - Single File

```bash
python convert_single.py input.pdf output_dir/ --output_format markdown
```

### CLI - Batch Processing

```bash
python convert.py input_dir/ output_dir/ --workers 4
```

### Python API

```python
from marker.converters.pdf import PdfConverter
from marker.models import create_model_dict

models = create_model_dict()
converter = PdfConverter(artifact_dict=models)
rendered = converter("document.pdf")

# rendered.markdown - Markdown text
# rendered.images - Dict of extracted images
# rendered.metadata - TOC, page stats
```

### REST API

```bash
python marker_server.py  # Starts FastAPI server

curl -X POST http://localhost:8000/marker \
  -F "file=@document.pdf" \
  -F "output_format=markdown"
```

---

## Configuration

Key options (via CLI or config dict):

| Option | Description |
|--------|-------------|
| `--output_format` | markdown, json, html, chunks |
| `--page_range` | Pages to process (e.g., "0,5-10,20") |
| `--force_ocr` | Skip text extraction, use OCR |
| `--disable_image_extraction` | Don't extract images |
| `--use_llm` | Enable LLM-enhanced processing |
| `--debug` | Generate visual debug output |

---

## Document Schema

```
Document
├── pages: List[PageGroup]
│   ├── lowres_image, highres_image
│   ├── children: List[Block]
│   │   ├── Text, Table, Figure, Equation, etc.
│   │   │   ├── polygon: PolygonBox
│   │   │   ├── structure: List[BlockId]
│   │   │   │   └── Line → Span → Char
│   └── structure: List[BlockId] (reading order)
└── table_of_contents: List[TocItem]
```

**Block Types:** Text, TextInlineMath, SectionHeader, Table, TableCell, Equation, Code, BlockQuote, Picture, Figure, FigureCaption, ListGroup, ListItem, PageHeader, PageFooter, Reference, Footnote, ComplexRegion, Form, Handwriting, TableOfContents

---

## Output Files

For `document.pdf`:
- `document.md` - Main markdown output
- `document_meta.json` - Table of contents, page stats
- `image_*.jpg` - Extracted images

**Metadata structure:**
```json
{
  "table_of_contents": [
    { "title": "Section", "heading_level": 1, "page_id": 0 }
  ],
  "page_stats": [
    { "page_id": 0, "text_extraction_method": "pdftext", "block_counts": [...] }
  ]
}
```

---

## Key Dependencies

| Library | Purpose |
|---------|---------|
| `surya-ocr` | Layout detection, OCR, table recognition |
| `pdftext` | PDF text extraction |
| `pypdfium2` | PDF rendering |
| `weasyprint` | HTML to PDF conversion |
| `markdownify` | HTML to Markdown |
| `mammoth` | DOCX parsing |
| `python-pptx` | PowerPoint parsing |
| `openpyxl` | Excel parsing |
| `ebooklib` | EPUB parsing |

---

## Performance

- **Hybrid text extraction**: Uses PDF text when valid (~80% of pages), OCR only when needed
- **Batch processing**: Configurable batch sizes per device (CUDA/MPS/CPU)
- **Multiprocessing**: Worker pools with model preloading
- **LLM enhancement**: Optional, runs in thread pool (max 3 concurrent)

---

## File Structure

```
marker/
├── convert.py              # Batch CLI
├── convert_single.py       # Single file CLI
├── marker_server.py        # REST API
├── marker/
│   ├── converters/         # PdfConverter, ExtractionConverter
│   ├── builders/           # Document, Layout, Line, OCR, Structure
│   ├── processors/         # 23+ content processors
│   │   └── llm/            # LLM-enhanced processors
│   ├── providers/          # Format-specific extractors
│   ├── renderers/          # Output formatters
│   ├── schema/             # Data models (Document, Block, etc.)
│   └── services/           # LLM services (Gemini)
└── benchmarks/             # Performance testing
```
