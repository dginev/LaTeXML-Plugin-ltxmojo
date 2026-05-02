import { Idiomorph } from "idiomorph";

const PARSER = new DOMParser();

export function renderResult(html: string): void {
  const preview = document.getElementById("preview")!;
  const log = document.getElementById("log")!;
  log.hidden = true;
  preview.hidden = false;

  // Parse the fragment safely: wrap in a body so the parser is happy.
  const doc = PARSER.parseFromString(`<div id="preview-root">${html}</div>`, "text/html");
  const incoming = doc.getElementById("preview-root");
  if (!incoming) {
    preview.innerHTML = html;
    return;
  }
  // Morph: preserves caret, scroll, focus where possible.
  Idiomorph.morph(preview, incoming, { morphStyle: "innerHTML" });

  // Best-effort math fallback: if browser MathML support is missing, lazy-load
  // KaTeX and re-render <math> nodes. Done here rather than at module top so
  // the bundle stays small for browsers that already render MathML natively.
  if (!supportsMathML() && preview.querySelector("math")) {
    void renderMathFallback(preview);
  }
}

export function showLog(text: string): void {
  const preview = document.getElementById("preview")!;
  const log = document.getElementById("log")!;
  log.textContent = text;
  preview.hidden = true;
  log.hidden = false;
}

function supportsMathML(): boolean {
  // Heuristic: render a MathML node off-screen and inspect its layout.
  const probe = document.createElementNS("http://www.w3.org/1998/Math/MathML", "math");
  probe.innerHTML = "<mspace height=\"23px\" width=\"77px\"/>";
  probe.style.position = "absolute";
  probe.style.visibility = "hidden";
  document.body.appendChild(probe);
  const ok = probe.getBoundingClientRect().height > 5;
  probe.remove();
  return ok;
}

async function renderMathFallback(root: HTMLElement): Promise<void> {
  const [{ default: katex }] = await Promise.all([
    import("katex"),
    import("katex/dist/katex.min.css"),
  ]);
  for (const node of Array.from(root.querySelectorAll("math"))) {
    const tex = node.querySelector("annotation[encoding=\"application/x-tex\"]")?.textContent;
    if (!tex) continue;
    const span = document.createElement("span");
    try {
      katex.render(tex, span, { throwOnError: false, output: "html" });
      node.replaceWith(span);
    } catch {
      // fall through; leave the original <math> in place
    }
  }
}
