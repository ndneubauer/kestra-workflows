# Kestra workflow workspace guidance

## Scope

This repository contains Kestra flow definitions and the Docker Compose
configuration for the local Kestra stack. Keep workflow changes small,
deterministic, and easy to import into the running Kestra instance.

Do not put passwords, API keys, refresh tokens, or other credentials in flow
YAML, `AGENTS.md`, `README.md`, or examples. Runtime secrets belong in the root
`.env` file, which Docker Compose loads through `env_file`. Use `.env.example`
for variable names only.

## Kestra and mounted files

- The connected Kestra instance is normally the host at
  `the configured Kestra host`; a local `localhost:9002` instance may not be running.
- Docker Compose mounts this repository's `flows/` directory read-only at
  `/app/flows`. Editing a YAML file on the host does not automatically import
  or update the flow in Kestra.
- After changing a flow, manually import or save that flow in the connected
  Kestra UI. Verify the resulting revision or execution there. A manual run of
  an email workflow sends a real email, so do not use it as a harmless syntax
  check.
- After changing `.env`, recreate the Kestra service so the container receives
  the new environment: `docker compose up -d --force-recreate kestra`.

The Kestra service mounts `/tmp/kestra-wd:/tmp/kestra-wd` and configures
`/tmp/kestra-wd/tmp` as its task temp directory. Treat this as the intended
scratch location for task-local virtual environments, package caches, and
temporary files. Do not use it as durable storage or put secrets there.

## Python dependencies in Kestra tasks

Python dependencies are installed at task runtime inside the mounted scratch
area. The following failures have already occurred and should guide future
changes:

1. Requesting a managed interpreter by exact version produced:
   `Could not find or install Python '3.12.3' path`.
   Prefer the interpreter already present in the Kestra image, normally
   `/usr/bin/python`, for example:

   ```sh
   uv venv --python /usr/bin/python .venv
   uv pip install --python .venv/bin/python --quiet "package>=min,<max"
   export VIRTUAL_ENV="$(pwd)/.venv"
   ```

   Use the venv's explicit Python path when invoking scripts. Do not assume
   that Kestra can download or install an arbitrary Python version at runtime.

2. Installing the `caldav` dependency pulled in native `lxml` extensions and
   failed while loading a shared object under the task temp directory:
   `/tmp/kestra-wd/tmp/.../lxml/...so: failed to map segment from shared object`.
   Native packages can require image-level libraries, executable memory
   mappings, or a different filesystem setup than a task-local install
   provides. Avoid introducing native dependencies into a workflow unless the
   Kestra image and volume configuration have been deliberately changed and
   tested.

For CalDAV, the working approach is a pure-Python task-local environment using
`icalendar` and `recurring-ical-events`, with the standard-library
`urllib.request` WebDAV transport and `xml.etree.ElementTree` XML parsing. Keep
the dependency ranges bounded and install them in the `/tmp/kestra-wd`-backed
task workspace rather than into the container's system Python.

If a future dependency genuinely needs compiled extensions, prefer baking it
into a controlled Kestra image and validating it there. Do not silently fall
back to an unbounded `pip install` into system locations.

## Workflow conventions

- All current LLM operations use the `gemma4-nothink:12b` alias built from
  `ollama/gemma4-12b-nothink.Modelfile`. Its `gemma4-no-thinking` parser removes
  the thinking capability at the model level. Keep `thinkingEnabled: false`
  and `returnThinking: false` on Kestra `ChatCompletion` tasks, and keep
  `"think": false` on direct Ollama API calls, as defense in depth.
- Reuse existing SMTP plugin defaults and environment variables. Keep
  recipients and sender addresses explicit in the flow, but never copy the
  SMTP password into it.
- Keep factual collection and filtering deterministic. Treat LLM output as
  editorial copy, validate its shape and limits, and render exact event data
  from deterministic task output.
- For the weekly CalDAV digest, filtering applies only to `Shared`; `Events`
  remains unfiltered. Maintain the explicit Shared blacklist and the combined
  recurrence/amount rule in `weekly_caldav_events.yaml`.
- The digest schedule is Sunday at 6:00 pm in `Australia/Brisbane`.
- Error notifications go to the configured operational error recipient, not
  the normal digest recipient.

## Verification checklist

Before handing off a workflow change:

1. Run `git diff --check`.
2. Confirm no credentials or secret values were added to tracked files.
3. Import/save the changed flow in the connected Kestra instance.
4. For schedule changes, verify the trigger page shows the intended local next
   execution time and that the trigger is enabled.
5. For dependency changes, run the relevant task far enough to confirm the
   interpreter, package installation, and imports succeed. Inspect logs for
   the Python path and native-library loading errors.
