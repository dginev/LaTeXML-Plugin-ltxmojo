// Minimal seed set; port more from the Perl ltxmojo's examples.js as needed.
export const EXAMPLES: Record<string, string> = {
  "Pythagoras": String.raw`\(a^2 + b^2 = c^2\)`,

  "Quadratic": String.raw`\[ x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} \]`,

  "Maxwell": String.raw`\[
\begin{aligned}
\nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
\nabla \cdot \mathbf{B} &= 0 \\
\nabla \times \mathbf{E} &= -\frac{\partial \mathbf{B}}{\partial t} \\
\nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
\end{aligned}
\]`,

  "Article": String.raw`\documentclass{article}
\usepackage{amsmath}
\begin{document}
\section{Hello}
The Riemann zeta function is
\[ \zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s}. \]
\end{document}`,
};
