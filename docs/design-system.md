# loopctl Design System

**Version:** 1.0
**Date:** March 31, 2026
**Stack:** Phoenix LiveView + Tailwind CSS v4
**Component Base:** Phoenix core_components (customized)
**External Dependencies:** None (no daisyUI, no Flowbite, no component libraries)

---

## 1. Design Philosophy

### What loopctl Should FEEL Like

**A precision instrument for developers.** Think of a well-designed CLI, a code editor's settings panel, or Stripe's API dashboard. Every element serves a purpose. The interface communicates competence and clarity — the kind of tool that earns trust by being obviously well-engineered.

**Terminal meets dashboard.** loopctl's users are developers and AI agents. The aesthetic should bridge the gap between a terminal and a web app: monospace where precision matters, clean sans-serif where readability matters, and dark backgrounds that feel like home to someone who lives in a code editor.

**Information architecture over decoration.** Status, identity, and trust are loopctl's core concerns. The UI should make these instantly visible: which agent did what, when, and was it verified? Every state transition, every chain-of-custody step, every review finding should be scannable at a glance.

**Quiet confidence.** No visual noise. No attention-grabbing elements competing with each other. The interface recedes — you notice the data, not the chrome. When something demands attention (a blocked action, a failed verification), it earns that attention through contrast against the calm baseline.

### What loopctl Should NOT Feel Like

- **Generic SaaS** — No hero sections with gradient backgrounds. No "trusted by 10,000 teams" social proof banners. No illustration of cartoon developers collaborating. This is infrastructure, not a consumer product.
- **Playful startup** — No rounded-2xl cards, no bouncy animations, no emoji in the UI, no pastel accents. This tool enforces structural trust in AI development loops. The design should reflect that seriousness.
- **Enterprise dashboard** — No overwhelming sidebar with 50 nav items. No settings pages with nested tabs. Keep the surface area small and each view purposeful.
- **"AI slop" aesthetic** — No Inter on white with indigo-600 buttons. No glassmorphism. No gradient text. No soft shadows on floating cards. No generic admin template look.
- **Like freight-pilot** — loopctl is not an industrial tool for truckers. It is a precision tool for developers. Different audience, different aesthetic, different density model.

---

## 2. Color Palette

### Design Rationale

The palette draws from terminal aesthetics and code editor themes: deep blue-grays for backgrounds, crisp whites and light grays for text, and a single accent color for interactive elements and status. The blue tint in the grays evokes the cool glow of a monitor in a dark room — familiar territory for developers.

Dark mode is the **only** design target for v1. loopctl's users live in dark mode. There is no light mode.

### Core Palette

#### Primary: Indigo-Blue (Controlled Use)

The primary accent. Used sparingly for: CTAs, active navigation, links, and primary actions. NOT indigo-600 (the AI slop default) — a deeper, more muted blue that feels intentional.

| Token | Hex | Usage |
|-------|-----|-------|
| `--color-accent-900` | `#1e1b4b` | Accent backgrounds (dark) |
| `--color-accent-800` | `#283572` | Accent hover backgrounds |
| `--color-accent-700` | `#3451a1` | Primary button background |
| `--color-accent-600` | `#4263c9` | Primary button hover |
| `--color-accent-500` | `#5b7de6` | Links, interactive text |
| `--color-accent-400` | `#8098f0` | Light accent text |
| `--color-accent-300` | `#adb8f7` | Subtle accent highlights |
| `--color-accent-200` | `#d4dafb` | Light mode accent (future) |

#### Neutrals: Cool Gray (Slate)

Cool-toned grays with a slight blue undertone. These feel like a code editor, not a warm living room.

| Token | Hex | Usage |
|-------|-----|-------|
| `--color-slate-950` | `#0b0e14` | Page background (darkest) |
| `--color-slate-900` | `#111419` | Card backgrounds, sidebar |
| `--color-slate-850` | `#171b22` | Elevated surfaces, hover backgrounds |
| `--color-slate-800` | `#1e2028` | Input backgrounds, code blocks |
| `--color-slate-700` | `#2a2d36` | Borders, dividers |
| `--color-slate-600` | `#3d4150` | Muted text, disabled states |
| `--color-slate-500` | `#5a5f72` | Secondary text, placeholders |
| `--color-slate-400` | `#8b90a0` | Body text (secondary) |
| `--color-slate-300` | `#b4b8c7` | Body text (primary) |
| `--color-slate-200` | `#d4d7e0` | Headings, emphasis |
| `--color-slate-100` | `#e8eaf0` | High-emphasis text |
| `--color-slate-50` | `#f4f5f7` | Maximum emphasis (rare) |

#### Semantic / Status Colors

| Token | Hex | Usage |
|-------|-----|-------|
| `--color-success-500` | `#34d399` | Verified, passed, complete |
| `--color-success-900` | `#064e3b` | Success background |
| `--color-warning-500` | `#fbbf24` | Pending, in-progress, needs attention |
| `--color-warning-900` | `#451a03` | Warning background |
| `--color-danger-500` | `#f87171` | Failed, blocked, error |
| `--color-danger-900` | `#450a0a` | Error background |
| `--color-info-500` | `#60a5fa` | Informational, neutral status |

#### Story/Agent Status Colors

These map directly to loopctl's domain model:

| Status | Token | Color | Hex |
|--------|-------|-------|-----|
| Pending | `status-pending` | Gray | `--color-slate-500` |
| Contracted | `status-contracted` | Blue | `--color-info-500` |
| Implementing | `status-implementing` | Amber | `--color-warning-500` |
| Reported Done | `status-reported` | Teal | `#2dd4bf` |
| Reviewing | `status-reviewing` | Purple | `#a78bfa` |
| Verified | `status-verified` | Green | `--color-success-500` |
| Rejected | `status-rejected` | Red | `--color-danger-500` |
| Blocked | `status-blocked` | Red (muted) | `#fb7185` |

---

## 3. Typography

### Font Pairing

| Role | Font | Fallback | Usage |
|------|------|----------|-------|
| **Display/Heading** | Geist | system-ui, sans-serif | Page titles, hero text, section headers |
| **Body** | Geist | system-ui, sans-serif | Paragraphs, descriptions, labels |
| **Mono** | Geist Mono | ui-monospace, monospace | Agent IDs, story IDs, API keys, code blocks, JSON, status labels |

### Why Geist

Geist is Vercel's open-source typeface, designed specifically for developer tools. It has excellent readability at small sizes, a monospace variant that pairs perfectly, and a technical-but-not-cold personality. It signals "developer infrastructure" without saying it.

### Loading Fonts

In `root.html.heex`:
```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
```

In `app.css`:
```css
@theme {
  --font-display: "Geist", system-ui, sans-serif;
  --font-body: "Geist", system-ui, sans-serif;
  --font-mono: "Geist Mono", ui-monospace, monospace;
}
```

### Type Scale

| Element | Size | Weight | Font | Color |
|---------|------|--------|------|-------|
| Hero headline | `text-4xl` (36px) | 700 | display | `slate-50` |
| Page title | `text-2xl` (24px) | 600 | display | `slate-100` |
| Section heading | `text-lg` (18px) | 600 | display | `slate-200` |
| Card heading | `text-sm` (14px) | 600 | display | `slate-200` |
| Body text | `text-sm` (14px) | 400 | body | `slate-300` |
| Secondary text | `text-sm` (14px) | 400 | body | `slate-400` |
| Caption/label | `text-xs` (12px) | 500 | body | `slate-500` |
| Code/IDs | `text-sm` (14px) | 400 | mono | `slate-300` |
| Code inline | `text-xs` (12px) | 400 | mono | `accent-400` |
| Status badge | `text-xs` (12px) | 500 | mono | per-status |

---

## 4. Spacing & Layout

### Spacing Scale

Use Tailwind's default scale. Key values:
- `p-1` (4px) — tight: inside badges, between inline elements
- `p-2` (8px) — compact: table cells, list items
- `p-3` (12px) — default: inside cards, form groups
- `p-4` (16px) — comfortable: section padding, modal padding
- `p-6` (24px) — spacious: page padding, between major sections
- `p-8` (32px) — generous: hero section padding, landing page sections

### Layout Principles

- **Max width**: Landing page content maxes at `max-w-5xl` (64rem / 1024px). Admin pages can go wider.
- **Grid**: Use CSS Grid for page layout, Flexbox for component internals.
- **Cards**: Minimal border (`border border-slate-700`), subtle background lift (`bg-slate-900`), no shadow. Cards communicate grouping through border, not elevation.
- **Border radius**: `rounded-md` (6px) for cards and buttons. `rounded-sm` (2px) for badges and inputs. Never `rounded-xl` or `rounded-2xl`.

---

## 5. Component Patterns

### Buttons

```heex
<%!-- Primary --%>
<button class="bg-accent-700 hover:bg-accent-600 text-white text-sm font-medium px-4 py-2 rounded-md transition-colors">
  Get Started
</button>

<%!-- Secondary --%>
<button class="bg-slate-800 hover:bg-slate-700 text-slate-200 text-sm font-medium px-4 py-2 rounded-md border border-slate-600 transition-colors">
  View Docs
</button>

<%!-- Ghost --%>
<button class="text-slate-400 hover:text-slate-200 text-sm font-medium px-3 py-2 transition-colors">
  Cancel
</button>
```

### Cards

```heex
<div class="bg-slate-900 border border-slate-700 rounded-md p-4">
  <h3 class="font-display text-sm font-semibold text-slate-200">Title</h3>
  <p class="font-body text-sm text-slate-400 mt-1">Description</p>
</div>
```

- No shadow on inline cards — borders provide structure
- No gradient backgrounds
- Hover: `hover:border-slate-600` for interactive cards

### Code Blocks

```heex
<div class="bg-slate-800 border border-slate-700 rounded-md p-4 font-mono text-sm text-slate-300 overflow-x-auto">
  <pre><code>curl -H "Authorization: Bearer $KEY" https://loopctl.com/api/v1/stories</code></pre>
</div>
```

### Status Badges

```heex
<span class={["inline-flex items-center px-2 py-0.5 text-xs font-mono font-medium rounded-sm", status_class(@status)]}>
  {@status}
</span>
```

Status classes:
```elixir
defp status_class("verified"), do: "bg-success-900 text-success-500"
defp status_class("implementing"), do: "bg-warning-900 text-warning-500"
defp status_class("rejected"), do: "bg-danger-900 text-danger-500"
defp status_class("pending"), do: "bg-slate-800 text-slate-400"
defp status_class(_), do: "bg-slate-800 text-slate-400"
```

### Navigation (Landing Page)

```heex
<nav class="sticky top-0 z-50 bg-slate-950/90 backdrop-blur-sm border-b border-slate-800">
  <div class="max-w-5xl mx-auto px-6 h-14 flex items-center justify-between">
    <a href="/" class="font-mono text-sm font-semibold text-slate-100">loopctl</a>
    <div class="flex items-center gap-6 text-sm text-slate-400">
      <a href="#features" class="hover:text-slate-200 transition-colors">Features</a>
      <a href="/docs" class="hover:text-slate-200 transition-colors">Docs</a>
      <a href="/api/v1/" class="hover:text-slate-200 transition-colors">API</a>
      <a href="https://github.com/..." class="hover:text-slate-200 transition-colors">GitHub</a>
      <a href="/signup" class="bg-accent-700 hover:bg-accent-600 text-white px-3 py-1.5 rounded-md transition-colors">Get Started</a>
    </div>
  </div>
</nav>
```

- Logo is monospace, lowercase — `loopctl` is a CLI-first tool
- Backdrop blur only on the navbar (it serves a functional purpose here)
- Compact height (56px)

### Tables (Admin Pages)

```heex
<table class="w-full text-sm">
  <thead class="border-b border-slate-700 text-slate-500 text-left text-xs font-mono uppercase tracking-wider">
    <tr>
      <th class="py-2 px-3">Story</th>
      <th class="py-2 px-3">Status</th>
      <th class="py-2 px-3">Agent</th>
    </tr>
  </thead>
  <tbody class="divide-y divide-slate-800">
    <tr class="hover:bg-slate-850">
      <td class="py-2 px-3 font-mono text-slate-300">US-7.3</td>
      <td class="py-2 px-3"><.status_badge status="verified" /></td>
      <td class="py-2 px-3 font-mono text-slate-400">agent-alpha</td>
    </tr>
  </tbody>
</table>
```

- Mono font for IDs, agent names, timestamps
- Minimal row padding
- Header is uppercase mono — reinforces the terminal aesthetic
- Hover state for scannability

---

## 6. Motion & Interaction

### Principles

- **Instant feels best.** Transitions under 150ms. No easing curves that draw attention.
- **Functional only.** Animate to communicate state change (hover, focus, appear/disappear). Never animate for decoration.
- **No bounce, no spring.** `ease-out` for enter, `ease-in` for exit. Never `bounce` or `spring`.

### Transitions

```css
/* Default transition for interactive elements */
.transition-colors { transition: color 100ms ease-out, background-color 100ms ease-out, border-color 100ms ease-out; }

/* Page load fade-in */
.phx-connected { transition: opacity 100ms ease-out; }
.phx-loading { opacity: 0.8; }
```

---

## 7. Landing Page Specific

### Hero Section

```heex
<section class="max-w-5xl mx-auto px-6 pt-24 pb-16">
  <h1 class="font-display text-4xl font-bold text-slate-50 max-w-2xl">
    Structural trust for AI development loops
  </h1>
  <p class="font-body text-lg text-slate-400 mt-4 max-w-xl">
    loopctl enforces that AI agents follow the process — not just promise to.
    Chain-of-custody verification, review enforcement, and progress tracking as API primitives.
  </p>
  <div class="flex gap-3 mt-8">
    <a href="/signup" class="bg-accent-700 hover:bg-accent-600 text-white text-sm font-medium px-5 py-2.5 rounded-md transition-colors">
      Get Started
    </a>
    <a href="https://github.com/..." class="bg-slate-800 hover:bg-slate-700 text-slate-200 text-sm font-medium px-5 py-2.5 rounded-md border border-slate-600 transition-colors">
      View on GitHub
    </a>
  </div>
</section>
```

- Left-aligned text (not centered — centered heroes feel generic)
- Max-width on text blocks for readability (65-75 characters per line)
- Two CTAs: primary (sign up) and secondary (GitHub)
- No illustration, no screenshot — the product is an API, show code instead

### Feature Cards

Show features as a grid of cards. Each card: icon (optional, hero-icon), title, 1-2 sentence description. 3-column grid on desktop, stack on mobile.

### Code Example Section

A live code example showing a curl command or MCP tool call. Dark code block with syntax-highlighted output. This IS the product demo — no screenshots needed.

### Social Proof (Eventually)

When available: logos of projects using loopctl, or a count of stories tracked. Until then, skip this section entirely — empty social proof is worse than none.

---

## 8. Responsive Design

### Breakpoint Strategy

- **Mobile (< 640px)**: Single column, larger touch targets (44px), stacked nav
- **Tablet (640-1024px)**: Two-column feature grid, condensed nav
- **Desktop (1024+)**: Full layout, three-column feature grid, horizontal nav

### Mobile Navigation

On mobile, collapse nav links behind a hamburger menu. Keep the logo and primary CTA visible.

---

## 9. Accessibility (Non-Negotiable)

- **Contrast**: 4.5:1 minimum for body text, 3:1 for large text — verify all slate-on-slate combinations
- **Focus indicators**: `ring-2 ring-accent-500 ring-offset-2 ring-offset-slate-950` on all interactive elements
- **Semantic HTML**: `<nav>`, `<main>`, `<article>`, `<section>`, `<footer>` — not just `<div>`
- **ARIA labels**: On icon-only buttons, code blocks (role="code"), and navigation landmarks
- **Keyboard navigation**: All actions reachable via Tab + Enter
- **Skip to content**: Add a skip link before the nav for screen readers

---

## 10. Anti-Patterns (Hard Rules)

These will be rejected in review:

- [ ] `rounded-xl` or `rounded-2xl` on any element
- [ ] Gradient backgrounds (solid colors only)
- [ ] Shadow on inline cards (`shadow-md`, `shadow-lg`, etc.)
- [ ] Glassmorphism (`backdrop-blur` on transparent white)
- [ ] Bouncy or spring animations
- [ ] Inter, Roboto, or Arial as the primary font
- [ ] Raw Tailwind colors (use design tokens: `slate-*`, `accent-*`, `success-*`, etc.)
- [ ] Centered hero text (left-align)
- [ ] Stock illustrations or generic SVG art
- [ ] More than 2 font families in use simultaneously
- [ ] `text-white` on body text (use `slate-300` for body, `slate-100`/`slate-50` for headings)
- [ ] Any warm-toned grays (this is a cool-toned project — use slate, not stone/zinc/gray)
