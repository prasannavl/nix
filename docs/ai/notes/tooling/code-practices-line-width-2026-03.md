# Code Practices: Line Width (2026-03)

## Scope

Supporting analysis for the repo's common line-width recommendation in
`docs/ai/lang-patterns/common.md`.

## Recommendation summary

- Recommended default:
  - code at `100` columns
  - comments at `80` columns
  - `120` columns as a hard maximum
- Treat line width as a collaboration constraint, not as a universal cognitive
  constant or scientifically proven optimum.

## Main inference

- The classic `80`-column rule is partly historical and partly operational.
- The evidence does not show that exactly `80` columns is universally optimal.
- The evidence does support avoiding long lines and rightward drift.
- Modern ecosystem defaults cluster around `88` to `100` for code, while prose
  and comments often remain closer to `80`.

## Evidence snapshot

- The strongest broad summary we have is Oliveira et al. (2023), a systematic
  literature review of formatting elements and code legibility. It explicitly
  says the area is immature and many studies are inconclusive.
- For line length specifically, that review found only one direct study in its
  corpus: Santos and Gerosa (2018).
- Santos and Gerosa (2018) ran an opinion survey with 62 Java readers (55
  students and 7 professionals). Their `P.4` practice, "line lengths not
  exceeding 80 chars", was preferred over the violating variant (`44` votes to
  `15`, `p = 0.0003`).
- That result is useful, but it is still an opinion-preference result on Java
  snippets, not a universal comprehension-speed law for all code.
- Dorn (2012), in a larger human-study-driven readability model with more than
  5,000 participants, found that long lines decrease readability in aggregate
  and that line length was the most significant feature across all samples and
  for Java specifically. The same paper also reports that line length did not
  play the same role for Python-only judgments, which is a good reminder that
  the effect is real but not language-independent.
- Typography research is directionally supportive but only analogical. For
  example, Dyson (2004) found that line length affects on-screen reading of
  prose, with tradeoffs between speed, preference, and comprehension. That is
  useful background, but it should not be misrepresented as a direct code-width
  study.

## Practical interpretation

- Do not argue that `80` is scientifically proven as the optimal code width.
- Do argue that moderate limits improve interoperability across terminals,
  review UIs, split panes, and side-by-side diffs.
- Prefer the existing formatter or language-community default over inventing a
  repo-local number without a reason.
- When no standard exists, `100` for code with `80` for comments is a practical
  compromise: modern enough for current tooling, still narrow enough for review
  ergonomics, and consistent with the general range used by current style
  guides.
- Treat `120` as overflow tolerance rather than the working target.

## Useful references

- Studies and reviews:
  - Oliveira et al. (2023), "A systematic literature review on the impact of
    formatting elements on code legibility":
    <https://prg.is.titech.ac.jp/papers/pdf/jss2023.pdf>
  - Santos and Gerosa (2018), "Impacts of Coding Practices on Readability":
    <https://www.ime.usp.br/~gerosa/papers/ICPC2018-Legibility.pdf>
  - Dorn (2012), "A General Software Readability Model":
    <https://web.eecs.umich.edu/~weimerw/students/dorn-mcs-paper.pdf>
  - Buse and Weimer (2010), "Learning a Metric for Code Readability":
    <https://web.eecs.umich.edu/~weimerw/p/weimer-tse2010-readability-preprint.pdf>
  - Dyson (2004), "How physical text layout affects reading from screen":
    <https://stu.westga.edu/~ssynan1/literacy/Dyson.pdf>
- Discussion and synthesis:
  - Stack Overflow, "Studies on optimal code width":
    <https://stackoverflow.com/questions/578059/studies-on-optimal-code-width>
- Current style-guide defaults worth citing in discussions:
  - PEP 8: `79` characters for Python code: <https://peps.python.org/pep-0008/>
  - Black: default line length `88`:
    <https://black.readthedocs.io/en/stable/the_black_code_style/current_style.html>
  - Google Java Style Guide: column limit `100`:
    <https://google.github.io/styleguide/javaguide.html>
  - Rust Style Guide: maximum width `100`, with standalone comments typically
    limited to `80`: <https://doc.rust-lang.org/style-guide/>
