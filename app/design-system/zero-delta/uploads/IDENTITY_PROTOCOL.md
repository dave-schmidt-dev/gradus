# Identity Protocol: David M. Schmidt (Z-DELTA)

## 1. Core Philosophy: "The Two Sides of the Coin"
The digital presence is divided into two distinct but complementary personas. They share a common structural foundation but exist in opposing visual states.

### Persona A: The Builder (./zero [dave])
- **Domain:** `zerodave.dev`
- **Context:** Technical sandbox, project documentation, code execution.
- **Visual State:** Dark Mode (The "Tails" side).
- **Aesthetic:** Submerged, high-tech, executable (Terminal Black + Execution Cyan).

### Persona B: The Consultant (Zero Delta LLC)
- **Domain:** `zerodelta.dev`
- **Context:** Business consulting, corporate presence, compliance.
- **Visual State:** Light Mode (The "Heads" side).
- **Aesthetic:** High-contrast, professional, document-ready (Paper White + Status Green).

---

## 2. Foundational UI/UX Principles (MANDATORY)

All frontend, design, and LLM-driven UI work MUST adhere to the following four principles:

### I. Parallel Design
- **Structural Consistency:** The underlying layout, grid structures, padding, and spacing MUST remain identical across different domains.
- **Thematic Flipping:** A card on `zerodave.dev` and a card on `zerodelta.dev` should have the exact same HTML structure, changing only the CSS variables (Dark/Cyan vs. Light/Green) to reflect the active persona. 
- **The Bridge (`daveschmidt.dev`):** The central hub must use a "Neutral Professional" blend that references both sides (e.g., light background, dark slate text, green hover states, cyan subtle accents).

### II. Extreme Legibility
- **High Contrast Only:** Never use low-contrast combinations (e.g., light gray text on a white background, or dark gray on black). Ensure text easily passes WCAG AA contrast standards.
- **Typography Splitting:** 
  - **Prose/Summary:** Use a highly legible sans-serif font (e.g., `Inter`, system UI font) for comfortable reading.
  - **Data/Technical:** Use strict monospace fonts (`Courier New`) for dates, company names, code, headers, and metadata to preserve the engineering aesthetic.

### III. Descriptive Accessibility
- **Contextual Alt & Title Text:** `alt` and `title` attributes must never be lazy or repetitive. They must provide clear, actionable context to the user.
  - *BAD:* `title="zerodelta.dev"`
  - *GOOD:* `title="View Zero Delta LLC Consulting Services"`
- **Screen Readers & Hover States:** Hovering over any link or image should immediately inform the user of the exact intent and destination of that element.

### IV. Grounded Verification (Proof of Work)
- **Mini-Icons:** Every listed company, institution, or organization MUST be accompanied by a visually crisp `16x16` or `32x32` mini-icon (favicon or SVG).
  - *Rule:* Use local static fallbacks (`usmc.png`, `cipherblade.ico`) to prevent external API rate-limiting or broken images. Ensure `object-fit: contain` is used so logos are never squished.
- **Deep Linking:** Educational degrees, certifications, and project claims must include direct, dashed-underline links (e.g., "View Program Details") to the official source verifying the claim.
- **CSS Badges (Shields):** Technical skills and metadata should be formatted using pure-CSS, `shields.io`-style two-tone badges (Label + Value) rather than comma-separated lists.

---

## 3. Strict Constraints (Anti-Slop Protocol)
1. **No Em-Dashes:** Use single dashes or semicolons. No "AI-style" prose.
2. **No Unsubstantiated Claims:** Only information found in `data/resume.yaml` is permissible.
3. **No Decorative LLMs:** Do not list "Claude" or "Gemini" as tools. They are model families. Use exact tooling like "OpenAI Codex" or "GitHub Copilot".
4. **Genericized Military:** Do not list specific units (MCIA, I MEF, etc.) or specific throughput metrics. Use generic technical descriptions.
5. **Privacy First:** Never display phone numbers or personal physical addresses on public-facing sites.

---

## 4. Domain Hierarchy
1. **`daveschmidt.dev`** (Root/Resume) -> The Master Record. Links to A and B.
2. **`zerodave.dev`** (Technical) -> The Sandbox. Links back to Root.
3. **`zerodelta.dev`** (LLC) -> The Business. Links back to Root.

*Last Updated: March 2026*