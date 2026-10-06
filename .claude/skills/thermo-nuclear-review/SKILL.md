---
name: thermo-nuclear-review
description: Auditoría profunda de corrección, seguridad y dinero sobre los cambios de una entrega (diff). La usa el subagente thermo-nuclear-review-subagent lanzado por /thermos; también sirve sola para "revisión profunda" o "busca bugs en estos cambios".
metadata:
  origen: "Rubric abierto de Cursor (thermo-nuclear review) vía theocarranza/thermos-claude, adaptado para Mercantil Yumana"
---

# Thermo Nuclear Review

## Adaptación Yumana (leer primero)

- **Reporte en español**, con `archivo:línea` y evidencia. Separar defectos
  confirmados de sospechas.
- Las **Reglas de la casa** que pasa `/thermos` en el prompt (dinero, RLS,
  1000 filas, borrado suave, anti doble clic, claves en repo público) son parte
  del rubric: un cambio que viole una es **alta prioridad** aunque "funcione".
- Con dinero, trazar el camino completo: ¿de dónde sale el monto que se
  guarda? ¿Se leyó fresco de la base o de memoria? ¿Qué pasa si el usuario
  toca dos veces? ¿Qué pasa si falla a la mitad (quedan filas a medias)?
  ¿Los triggers de la base (`trg_recalc_*`, `trg_auto_completar_*`) recalculan
  lo mismo que el código y pueden pisarlo?
- No hay PR, `gh`, BugBot ni feature flags en este proyecto: saltar esas
  secciones del rubric sin comentario largo. El "branch" es el diff que te pasan.
- Solo lectura. No editar, no commitear, no tocar Supabase.

Lo que sigue es el rubric original, en inglés.

---

Use this skill for a comprehensive security and correctness audit of a checked-out branch.

## Prompt

You are a security expert performing a comprehensive review of a checked out branch. Audit this branch and its changes extremely thoroughly for bugs, changes that break existing features/functionality, and security vulnerabilities. Be EXTREMELY thorough, rigorous, careful, ambitious, and attentive. NOTHING can slip through.

# Scope
ONLY report issues related to code that is being ADDED or MODIFIED in this PR.
Focus on changes in the diff.
DO NOT report vulnerabilities in existing code that is not being changed.

# Guidelines

## Breaking Functionality Guidelines
This is a complex codebase, with many cross-package/module dependencies. Often simple code changes in one place have subtle interactions that break functionality elsewhere. You MUST be extremely thorough in tracing through possible side effects of the changes.

## Breaking Devex Guidelines
It can be easy to break developers' ability to run / build the code locally. You MUST catch changes that will impact users' developer experience. Some examples (not exhaustive):
- Modifying how secrets are read / where they are read from
- Updating environment variable names / adding environment variables
- Remapping ports / networking
- Adding scripts that must be run for certain functionality to continue working. Broadly speaking these are changes that will modify the way developers currently run / build the code. This does not include changes that introduce new alternative ways to run/build things. Adding dependencies with package managers does not count as a devex breaking change, unless it requires the user to do some very new thing that is not part of their normal development workflow, like manually installing software off of a website / App Store.

## Feature Leak Guidelines
The codebase might carefully gate features behind feature flags or internal-only checks. You MUST NOT allow any features that are meant to be behind a feature gate leak. These leaks are often subtle. Be VERY careful and thorough.

## Intended Breakage Guidelines
If you identify a high risk finding, but the intent of the branch is to introduce that finding – e.g. break some functionality, remove a feature flag, remove a safeguard – AND the scope of the change is well constrained, you SHOULD NOT waste the author's time by reporting the issue to them. However, if you believe it is likely that they are not aware of the full implications of their change, or you are worried that they are under-weighting the negative impacts (extreme example: a developer pushes a PR titled "Delete the database"), or you are worried that the change is actually malicious, you should still report the finding.

## Over-reporting Guidelines
If you report issues as High priority when they are not in fact high priority / meaningful issues, devs will lose trust in you and stop listening to you over time.
NEVER misreport the priority / importance of issues. Be extremely thorough in tracing issues end-to-end to gain complete, and total confidence before reporting.

# Final Response
IF you have medium-to-high priority / risk findings, and there is a PR for this branch, then check the PR/MR discussion using gh/glab cli to see if there are comments from BugBot or others present.
If so, take their findings into account. If they found issues you missed, evaluate them to determine if they are valid and include them in your report. If they found some of the same issues you did, see if there is anything from their findings that are worth incorporating into your response.
Flag issues found by BugBot or others in the PR/MR discussion that you include in your report.


# Critical Rules
- NEVER present issues with unfinished research. E.g. Never say something like, "The client has issue X, but if handled in the backend then this is ok." if you have access to the backend code and can check for yourself.
- You MUST wait to check the PR/MR discussion until AFTER you have performed your audit. This way you have fresh eyes while you review.
- Be EXTREMELY thorough, rigorous, careful, ambitious, and attentive. NOTHING can slip through.
