import { EditorState } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { latex } from "codemirror-lang-latex";

export interface EditorHandle {
  setSource(text: string): void;
  getSource(): string;
  onChange(cb: (tex: string) => void): void;
}

export function createEditor(host: HTMLElement): EditorHandle {
  let changeCb: ((tex: string) => void) | null = null;

  const view = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: "",
      extensions: [
        lineNumbers(),
        history(),
        highlightActiveLine(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        latex(),
        EditorView.lineWrapping,
        EditorView.updateListener.of((u) => {
          if (u.docChanged && changeCb) changeCb(u.state.doc.toString());
        }),
      ],
    }),
  });

  return {
    setSource(text) {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
      });
    },
    getSource() {
      return view.state.doc.toString();
    },
    onChange(cb) {
      changeCb = cb;
    },
  };
}
