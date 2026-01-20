# pdf2md1 Implementation Analysis

> JavaScript/PDF.js-based PDF to Markdown converter for PAG-23 integration evaluation

---

## 1. Implementation Approach

**pdf2md1** is a **client-side JavaScript PDF to Markdown converter** that extracts text using **Mozilla's PDF.js** library running in a browser environment.

### Core Method
- **PDF.js Text Content Extraction**: Uses `page.getTextContent()` to extract raw text items with spatial metadata (x, y coordinates, width, height, font name)
- **Multi-stage Transformation Pipeline**: Raw PDF text is progressively refined through 12+ sequential transformations
- **Heuristic-based Intelligence**: Uses font sizes, positioning, spacing patterns, and content analysis to infer document structure
- **Format Preservation**: Reconstructs document semantics (headers, lists, code blocks, TOC) from low-level PDF primitives

### Processing Model
```
PDF.js (Browser Worker)
    ↓ page.getTextContent()
TextItems (spatial coordinates, fonts)
    ↓ [CalculateGlobalStats]
Globals (height stats, font mappings, line distance)
    ↓ [CompactLines, LineConverter]
LineItems (words with formatting, links detected)
    ↓ [DetectHeaders, DetectTOC, DetectListItems]
Annotated LineItems (semantic block types assigned)
    ↓ [GatherBlocks, DetectCodeQuoteBlocks]
LineItemBlocks (grouped into semantic blocks)
    ↓ [ToTextBlocks, ToMarkdown]
Final Markdown Output
```

---

## 2. Architecture

### Entry Point & Main Flow

```
User drops/selects PDF
    ↓
LoadingView initiates PDF.js parsing
    ↓
AppState receives parsed pages + font map + metadata
    ↓
12-stage transformation pipeline executes
    ↓
ResultView displays final Markdown
```

### Core Transformation Pipeline (12 stages)

| Stage | Transformer | Purpose |
|-------|-------------|---------|
| 1 | `CalculateGlobalStats` | Analyze fonts, heights, line distances to establish statistics |
| 2 | `CompactLines` | Group TextItems on same Y-axis into LineItems |
| 3 | `RemoveRepetitiveElements` | Filter out headers, footers, repeated content |
| 4 | `VerticalToHorizontal` | Handle vertically-stacked text elements |
| 5 | `DetectTOC` | Identify table of contents pages and link headlines |
| 6 | `DetectHeaders` | Detect headers (H1-H6) based on font sizes |
| 7 | `DetectListItems` | Identify bullet/numbered lists |
| 8 | `GatherBlocks` | Group LineItems into blocks based on proximity |
| 9 | `DetectCodeQuoteBlocks` | Identify code/quote blocks |
| 10 | `DetectListLevels` | Determine list nesting levels |
| 11 | `ToTextBlocks` | Convert blocks to text with category metadata |
| 12 | `ToMarkdown` | Generate final Markdown output |

### Data Model Hierarchy

```
PageItem (abstract)
├── TextItem (x, y, width, height, text, font)
└── LineItem
    └── words: Word[]
        └── Word (string, type, format: BOLD/ITALIC/BOLD_ITALIC)

LineItemBlock
└── items: LineItem[]
└── type: BlockType (H1, H2, LIST, CODE, PARAGRAPH, etc.)

ParseResult
├── pages: Page[]
├── metadata: Metadata
└── globals: { mostUsedHeight, mostUsedFont, mostUsedDistance, fontToFormats }
```

---

## 3. Key Files

| File | Lines | Responsibility |
|------|-------|----------------|
| `src/javascript/components/LoadingView.jsx` | 257 | PDF.js integration; text extraction; font parsing; progress tracking |
| `src/javascript/components/AppState.jsx` | 82 | State container; orchestrates transformation pipeline |
| `src/javascript/models/transformations/LineConverter.jsx` | 169 | TextItems → LineItems; inline formatting detection (bold, italic, links) |
| `src/javascript/models/transformations/DetectHeaders.jsx` | 139 | H1-H6 detection via font size analysis and TOC matching |
| `src/javascript/models/transformations/DetectTOC.jsx` | 360 | TOC page identification; page reference extraction; headline linking |
| `src/javascript/models/transformations/DetectListItems.jsx` | 64 | Bullet (-, •, –) and numbered list detection |
| `src/javascript/models/transformations/GatherBlocks.jsx` | 88 | Group LineItems into semantic blocks |
| `src/javascript/models/transformations/CompactLines.jsx` | 85 | Group TextItems → LineItems; accumulate statistics |
| `src/javascript/models/transformations/CalculateGlobalStats.jsx` | 121 | Font usage, text heights, line spacing analysis |
| `src/javascript/models/BlockType.jsx` | 113 | Enum of Markdown block types with `toText()` methods |
| `src/javascript/models/TextItemLineGrouper.jsx` | 36 | Group TextItems by Y-axis proximity |

---

## 4. Text Extraction Details

### Header/Heading Detection

**Strategy** (DetectHeaders.jsx):

1. **Font height statistics collection**
   - Track all text heights and frequencies
   - Identify `mostUsedHeight` (typical body text)
   - Identify `maxHeight` (largest text, typically titles)

2. **Title page analysis**
   - Find pages with items at `maxHeight`
   - Mark items as H1 if height == maxHeight
   - Mark items as H2 if height > 25% above body text

3. **TOC-based hierarchy**
   - If TOC detected, use `headlineTypeToHeightRange` map
   - Match subsequent pages' text heights to known header heights

4. **Fallback heuristic**
   - Collect unique heights > `mostUsedHeight`
   - Sort heights descending
   - Assign H2, H3, H4... based on height ordering (max 6 levels)

5. **Uppercase text filtering**
   - Items with body height but UPPERCASE text + different font = header candidate

### Paragraph Handling

1. **TextItems → Lines**: Group by Y-coordinate (within `mostUsedDistance/2`)
2. **Lines → Words**: Split by spaces, detect formatting by font name:
   - Font contains "bold" → `WordFormat.BOLD`
   - Font contains "italic" or "oblique" → `WordFormat.OBLIQUE`
3. **Block assembly**: Adjacent lines grouped into PARAGRAPH blocks

### Table Processing

**Current Limitation**: Tables are NOT explicitly detected
- Tables treated as grouped lines/paragraphs or code blocks
- No cell structure preservation
- No special table-to-markdown conversion

### List Detection

**Bullet lists**:
- Detect lines starting with: `-`, `•`, `–`
- Add `-` prefix if not present

**Numbered lists**:
- Match pattern: `^\s*\d+\.\s+.*$`
- Preserve original numbering

**List block merging**: Consecutive list items grouped into single block

### Page Break Handling

- Each PDF page parsed separately
- Pages remain as separate items in `ParseResult.pages` array
- Distance-based break detection between lines
- Final output: pages concatenated with newlines

---

## 5. Dependencies

### Core Libraries

| Package | Version | Purpose |
|---------|---------|---------|
| **pdfjs-dist** | ^2.8.335 | Mozilla PDF.js - core PDF text extraction |
| **react** | ^15.4.2 | UI framework |
| **react-dom** | ^15.4.2 | React DOM rendering |
| **enumify** | ^1.0.4 | Enum type support (BlockType, WordFormat) |
| **remarkable** | ^1.7.1 | Markdown rendering for preview |

### Build Tools
- **webpack** - Module bundler
- **babel** - ES6+ transpilation
- **mocha/chai** - Testing

---

## 6. Limitations

### Text Extraction
- **No table detection**: Tables appear as sequential paragraphs
- **Two-column layouts not handled**: Processed as sequential lines
- **Scanned PDFs not supported**: Requires text layer (no OCR)
- **Font detection relies on naming**: Custom fonts may not be recognized
- **No subscript/superscript preservation**

### Architecture
- **Browser-only**: No Node.js/server-side support
- **React 15.4.2**: Outdated, no hooks
- **No TypeScript**: Minimal type safety
- **Memory concerns**: Large PDFs may cause issues

### Known Issues
- TOC page offset can be off by ±1 pages
- Header hierarchy may be incorrect for non-standard PDFs
- List level detection may fail with inconsistent spacing

---

## 7. PageFlow Relevance

### Portable Algorithms (HIGH VALUE)

These algorithms can be ported to Swift for native implementation:

| Algorithm | Source File | Swift Equivalent |
|-----------|-------------|------------------|
| **Header detection by font size** | `DetectHeaders.jsx` | Analyze `PDFPage` text attributes |
| **List item detection** | `DetectListItems.jsx` | Regex on extracted text |
| **Line grouping by Y-coordinate** | `TextItemLineGrouper.jsx` | Use `PDFSelection.selectionsByLine()` |
| **Font-based formatting** | `LineConverter.jsx` | PDFKit font attribute inspection |
| **TOC linking** | `DetectTOC.jsx` | Use `PDFDocument.outlineRoot` |

### Integration Approach: Native Swift Port

**Recommended for PageFlow** because:
1. PageFlow is offline-first - no API dependencies
2. PDFKit provides similar primitives to PDF.js
3. Algorithms are well-documented and testable
4. Start simple (text + headers), iterate

### Key Mapping: PDF.js → PDFKit

| PDF.js API | PDFKit Equivalent |
|------------|-------------------|
| `page.getTextContent()` | `PDFPage.string` or character-level iteration |
| `textItem.transform` (position) | `PDFSelection.bounds(for:)` |
| `textItem.fontName` | Font attributes from `PDFPage.attributedString` |
| `page.getViewport()` | `PDFPage.bounds(for: .mediaBox)` |

### Implementation Priority for PAG-23

1. **Phase 1**: Basic text extraction using `PDFPage.string`
2. **Phase 2**: Port header detection (font size analysis)
3. **Phase 3**: Port list detection (regex patterns)
4. **Phase 4**: Add TOC-based structure (leverage existing outline)

### What NOT to Port
- React UI components (use SwiftUI)
- Browser-specific workers (not needed)
- Progress tracking UI (different architecture)
