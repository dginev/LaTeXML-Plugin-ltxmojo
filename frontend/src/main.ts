import "./styles.css";
import { createEditor } from "./editor.ts";
import { ConvertClient } from "./ws.ts";
import { renderResult, showLog } from "./preview.ts";
import { EXAMPLES } from "./examples.ts";

const PREAMBLE_RE = /^([\s\S]*\\begin\{document\})([\s\S]*)\\end\{document\}([\s\S]*)$/;
const DEBOUNCE_MS = 300;

function statusEl(): HTMLElement {
  return document.getElementById("status")!;
}
function counterEl(): HTMLElement {
  return document.getElementById("counter")!;
}
function logEl(): HTMLElement {
  return document.getElementById("log")!;
}

function splitPreamble(tex: string): { preamble: string | null; body: string } {
  const m = PREAMBLE_RE.exec(tex);
  if (!m) return { preamble: null, body: tex };
  return { preamble: "literal:" + m[1], body: m[2] };
}

function bootExamples(view: { setSource: (s: string) => void }): void {
  const select = document.getElementById("example-select") as HTMLSelectElement;
  for (const name of Object.keys(EXAMPLES)) {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  }
  select.addEventListener("change", () => {
    const v = select.value;
    if (!v) return;
    view.setSource(EXAMPLES[v]!);
  });
}

function main(): void {
  const editor = createEditor(document.getElementById("codemirror-host")!);
  bootExamples(editor);

  const wsUrl =
    (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/convert";
  const client = new ConvertClient(wsUrl, {
    onMessage: (resp) => {
      counterEl().textContent = String(resp.id);
      if (resp.status_code === 3) {
        statusEl().textContent = "fatal";
        showLog(resp.log);
      } else {
        statusEl().textContent = resp.status || "ok";
        renderResult(resp.result);
        logEl().textContent = resp.log;
      }
    },
    onStatus: (s) => {
      statusEl().textContent = s;
    },
  });

  let nextId = 1;
  let timer: number | null = null;
  editor.onChange((tex) => {
    if (timer !== null) window.clearTimeout(timer);
    timer = window.setTimeout(() => {
      timer = null;
      const { preamble, body } = splitPreamble(tex);
      const id = nextId++;
      client.send({
        id,
        tex: body,
        preamble: preamble ?? undefined,
        profile: "fragment",
        format: "html5",
        preload: [
          "LaTeX.pool",
          "article.cls",
          "amsmath.sty",
          "amsthm.sty",
          "amstext.sty",
          "amssymb.sty",
          "eucal.sty",
          "[dvipsnames]xcolor.sty",
          "url.sty",
          "hyperref.sty",
          "[ids,mathlexemes]latexml.sty",
        ],
      });
      statusEl().textContent = "converting…";
    }, DEBOUNCE_MS);
  });

  // Fire one initial conversion of the seed text.
  editor.setSource("Write your LaTeX snippet…\n\nor pick an example from the dropdown.");
}

main();
