---
name: research-brief
description: Investigate an open-ended topic across current web sources and academic literature, compare evidence, and answer with traceable citations. Use for deep dives and literature overviews; use research-project when the user wants original experiments.
---

# Research brief

Use this skill for an on-demand investigation. Answer in chat unless the user
asks for a file or another deliverable.

1. Define the question's scope from the request: topic, period, geography, and
   what decision the answer should support. Clarify only a missing choice that
   would materially change the investigation.
2. Search current web sources and, for scholarly questions, the OpenAlex MCP
   research tools. Vary search terms and follow citation trails when the first
   results leave a gap. OpenAlex results are discovery metadata; use its query
   link or canonical OQL when the search method matters to the reader.
3. Open the underlying papers, official documentation, reports, or other
   primary sources before using them as evidence. Check publication and event
   dates separately, identify preprints, and verify important claims against
   more than one independent source when possible. For DOI or BibTeX details,
   use [[bibtex-fetch]] and Crossref as a second metadata check.
4. Compare findings and disagreements. A citation count, abstract, search
   snippet, or model-generated summary alone does not establish a paper's
   results. Do not invent a reference or imply full-text review when only
   metadata was available.
5. Lead the answer with the finding, then show the evidence and material
   uncertainty. Put direct links beside the claims they support. Include the
   research date for changing topics and briefly state search or access limits.

If OpenAlex is unavailable, unauthenticated, or out of budget, continue with
available web sources and Crossref, and say which scholarly checks were not
possible. Never submit OpenAlex account or author-profile changes as part of a
research brief.

For a question that needs new computational evidence and a written report,
use [[research-project]].
