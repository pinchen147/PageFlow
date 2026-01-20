# pdf2md2 Implementation Analysis

> Mistral OCR API-based SaaS PDF to Markdown converter for PAG-23 integration evaluation

---

## 1. Implementation Approach

**pdf2md2** is a **production SaaS application** that delegates PDF to Markdown conversion entirely to **Mistral's OCR API** (`mistral-ocr-latest` model).

### Core Method
- **External API Delegation**: All PDF parsing and markdown generation handled by Mistral OCR
- **File Upload Pipeline**: PDFs uploaded as base64 (small files) or via Cloudflare R2 URLs (large files)
- **Subscription Model**: Freemium with usage quotas and Stripe payment integration
- **No Custom Parsing**: Zero local PDF processing logic

### Processing Model
```
User Upload (Browser)
    ↓
Next.js Server Route (/api/convert)
    ↓
Authentication & Subscription Check
    ↓
File Size Routing:
├── < 5MB: Base64 encode, send directly
└── > 5MB: Upload to Cloudflare R2, send URL
    ↓
Mistral OCR API (External)
    ↓
Extract markdown from response.pages[].markdown
    ↓
Return to client for preview/download
```

---

## 2. Architecture

### Entry Points & Main Flow

```
Frontend (converter-section.tsx)
    ↓ File validation (type, size)
    ↓ Subscription status check
    ↓
POST /api/convert (FormData)
    ↓
Server Route (app/api/convert/route.ts)
    ↓ getServerSession() - Auth
    ↓ prisma.user.findUnique() - User lookup
    ↓ checkUserUsageLimit() - Quota check
    ↓ File size routing logic
    ↓
Mistral OCR API
    ↓
Response: { pages: [{ markdown: "..." }] }
    ↓
Join pages, return to client
```

### Key Components

| Component | File | Responsibility |
|-----------|------|----------------|
| **ConverterSection** | `components/converter-section.tsx` | Main UI: upload, validation, conversion trigger |
| **Convert API** | `app/api/convert/route.ts` | Server route: auth, file handling, Mistral orchestration |
| **PDF to Markdown** | `lib/pdf-to-markdown.ts` | Client helper for base64 conversion |
| **Usage Limits** | `lib/usage-limits.ts` | Free tier quota (5/month) |
| **Stripe Integration** | `lib/stripe-server.ts` | Payment processing |
| **R2 Upload** | Within convert route | Large file handling via Cloudflare R2 |

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ Client Browser                                                   │
├─────────────────────────────────────────────────────────────────┤
│  converter-section.tsx                                           │
│  ├─ File Upload (drag/drop)                                      │
│  ├─ Validation (type: PDF, size limits)                         │
│  └─ POST /api/convert                                            │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ Next.js Server                                                   │
├─────────────────────────────────────────────────────────────────┤
│ 1. Authentication (NextAuth)                                     │
│ 2. Subscription & usage check                                    │
│ 3. File size routing:                                            │
│    - Small: base64 encode                                        │
│    - Large: upload to R2                                         │
│ 4. Call Mistral OCR API                                          │
│ 5. Increment usage counter                                       │
│ 6. Return markdown                                               │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
        ┌──────────────────┐   ┌──────────────────────┐
        │ Mistral OCR API  │   │ PostgreSQL (Prisma)  │
        │                  │   │                      │
        │ Returns:         │   │ Tracks:              │
        │ { pages: [{      │   │ - usageCount         │
        │   markdown       │   │ - subscription       │
        │ }] }             │   │ - stripeCustomerId   │
        └──────────────────┘   └──────────────────────┘
```

---

## 3. Key Files

| File Path | Purpose |
|-----------|---------|
| `app/api/convert/route.ts` | **Core endpoint**: Auth, file handling, Mistral API calls, usage tracking |
| `components/converter-section.tsx` | Main UI component (~610 lines): upload, errors, subscription sync |
| `lib/pdf-to-markdown.ts` | Client-side helper for file→base64 conversion |
| `lib/usage-limits.ts` | Quota management: `FREE_USER_MONTHLY_LIMIT = 5` |
| `prisma/schema.prisma` | Data models: User, subscription fields, usage counters |
| `lib/stripe-server.ts` | Stripe client initialization |
| `app/api/check-subscription/route.ts` | Subscription status validation |
| `hooks/use-analytics.ts` | Google Analytics event tracking |

---

## 4. Text Extraction Details

### Header/Heading Detection
- **Handled entirely by Mistral OCR**
- API returns pre-formatted markdown with `#`, `##`, `###` etc.
- No custom heuristics in codebase

### Paragraph Handling
- Mistral OCR preserves text flow
- Multiple pages joined with `\n\n` separator
- No custom paragraph detection

### Table Processing
- **Mistral OCR converts tables to markdown format**
- No special table logic in codebase
- Quality depends on Mistral's table recognition

### Page Break Handling
```typescript
// From app/api/convert/route.ts (lines 395-398)
const markdownPages = Array.isArray(ocrResult.pages)
  ? ocrResult.pages.map((page: any) => page.markdown || '').join('\n\n')
  : '';
```
- Each page's markdown extracted from API response
- Pages joined with double newlines
- No explicit page break markers

---

## 5. Dependencies

### Core Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `next` | 15.2.4 | React framework & server routes |
| `react` | ^18.2.0 | UI library |
| `next-auth` | ^4.24.11 | Authentication |
| `@prisma/client` | ^5.5.2 | PostgreSQL ORM |
| `stripe` | ^18.1.0 | Payment processing |
| `@aws-sdk/client-s3` | ^3.806.0 | Cloudflare R2 uploads |
| `axios` | ^1.8.4 | HTTP requests to Mistral |
| `tailwindcss` | ^3.4.17 | Styling |
| `@radix-ui/*` | Various | UI primitives |
| `zod` | ^3.22.4 | Schema validation |

### External APIs
- **Mistral OCR**: `https://api.mistral.ai/v1/ocr` - Core extraction engine
- **Stripe API**: Payment and subscription management
- **Google Analytics**: Event tracking
- **Cloudflare R2**: Large file storage

---

## 6. Limitations

### API Dependency
- **Complete reliance on Mistral OCR** - no fallback
- **Requires internet** - no offline capability
- **API availability critical** - downtime = product down
- **Cost tied to Mistral pricing** - variable expenses

### File Size Constraints
- Free tier: 5MB maximum
- Premium tier: 30MB maximum (hardcoded)
- No streaming for very large PDFs

### Extraction Quality
- Entirely dependent on Mistral's model accuracy
- Scanned PDFs with poor quality may produce poor output
- No post-processing or cleanup of API output

### Subscription Model
- Cannot stack subscriptions
- Monthly reset always on 1st of next month
- Free tier: exactly 5 conversions/month

### Privacy Concerns
- PDFs sent to external API
- Data processed on Mistral servers
- Not suitable for sensitive documents without trust in Mistral

---

## 7. PageFlow Relevance

### Integration Viability: LOW

**pdf2md2's approach is NOT recommended for PageFlow** because:

1. **PageFlow is offline-first**: API dependency contradicts core design
2. **Privacy concerns**: Users may not want PDFs sent to external servers
3. **Cost model**: Per-conversion costs don't fit desktop app economics
4. **No portable algorithms**: All logic is in Mistral's black box

### What Could Be Reused

| Component | Usability | Notes |
|-----------|-----------|-------|
| **Mistral API integration** | Low | Would require API key management, costs |
| **Subscription infrastructure** | None | Not applicable to desktop app |
| **UI patterns** | Low | SwiftUI vs React |
| **File size routing** | None | Not needed for local processing |

### Alternative: API as Optional Enhancement

If desired, Mistral OCR could be offered as **optional premium feature**:

```swift
// Hypothetical optional API integration
enum MarkdownExportMethod {
    case native      // PDFKit-based, free, offline
    case mistralOCR  // API-based, better quality, requires internet
}
```

**Pros**: Better table/complex layout handling
**Cons**: API costs, internet required, privacy concerns

### Lessons Learned from pdf2md2

1. **Simple API design**: Single endpoint handles everything
2. **Error handling**: Graceful degradation on API failures
3. **Usage tracking**: Could be useful for analytics
4. **File size awareness**: Validate before processing

### Recommendation for PAG-23

**Do NOT use pdf2md2's approach for core implementation.**

Instead:
1. Use **pdf2md1's algorithms** ported to Swift (native, offline, free)
2. Leverage **PageFlow's existing PDFKit infrastructure**
3. Consider Mistral API only as future premium option

---

## Comparison Summary: pdf2md1 vs pdf2md2

| Aspect | pdf2md1 | pdf2md2 |
|--------|---------|---------|
| **Extraction Method** | Local (PDF.js) | External API (Mistral) |
| **Offline Support** | Yes (browser) | No |
| **Table Support** | No | Yes (via Mistral) |
| **Header Detection** | Font size heuristics | Mistral AI |
| **Portability** | High (algorithms portable) | Low (API black box) |
| **Cost** | Free | Per-conversion |
| **Privacy** | Local processing | Data sent to API |
| **PageFlow Fit** | Good (port algorithms) | Poor (contradicts offline-first) |

**Winner for PageFlow: pdf2md1** - Port the algorithms to Swift for native implementation.
