# jmportfolio — Johnny Mieses Portfolio

Personal portfolio hosted on GitHub Pages at https://jmieses.github.io/jmportfolio
Built with Jekyll using the Minimal Mistakes remote theme (v4.17.2).

## Critical constraints

- **GitHub Pages compatibility is non-negotiable.** This site deploys via GitHub Pages
  using the `github-pages` gem. Never upgrade Jekyll directly or add plugins that are
  not on the GitHub Pages whitelist. Before touching any dependency, verify it at
  https://pages.github.com/versions and https://pages.github.com/versions.json
- **Remote theme**: the site uses `remote_theme: "mmistakes/minimal-mistakes@4.17.2"`.
  Do not switch to a local `theme:` gem — that would break the GitHub Pages build.
- **Never edit `_site/`** — it is generated output and gitignored.
- **Never commit secrets** — `_config.yml` has blank fields for API keys, tracking IDs, etc.
  Keep them blank or use environment variables.
- **The deploy branch is `gh-pages`**, not `main`. All commits and pushes go to `gh-pages`.

## Project structure

```
_config.yml        — site config (server restart required after changes)
_data/             — YAML data files (navigation, UI text, etc.)
_includes/         — reusable HTML partials
_layouts/          — page layout templates
_pages/            — static pages (about, portfolio, etc.)
_posts/            — blog/project entries (requires front matter)
_sass/             — SCSS overrides for the theme
assets/            — CSS, JS, images (site-specific)
images/            — portfolio images
videos/            — portfolio videos
CNAME              — custom domain config — do not delete or modify
```

## Local development

The sandbox runs in Docker to isolate all Ruby/Jekyll dependencies.

```bash
# Start the live-reload dev server → http://localhost:4001
docker compose up

# Verify a build succeeds without errors (Claude uses this before committing)
docker compose run --rm build-check

# Rebuild image (only needed after Gemfile changes)
docker compose build
```

Host port 4001 maps to the container's port 4000 to serve the site (4000 on
the host conflicts with the `nxd.exe` Windows service). Port 35729 is the
livereload websocket — edits to
`_layouts/`, `_includes/`, `_pages/`, `_posts/`, and `_sass/` reflect instantly.
Changes to `_config.yml` require a container restart.

## Workflow

1. Always work on a feature branch, never commit directly to `gh-pages`.
2. Before proposing a commit, run `docker compose run --rm build-check` and confirm
   it exits with code 0 and no Liquid/YAML errors in the output.
3. Keep commits small with clear, descriptive messages. Never include
   `Co-Authored-By` trailers — commits are authored by Johnny Mieses alone.
4. After a successful build-check, push the branch and open a PR to `gh-pages`.
5. The human reviews the diff and merges — GitHub Pages deploys automatically.

## Plugins in use (all GitHub Pages whitelisted)

- jekyll-remote-theme
- jekyll-paginate
- jekyll-sitemap
- jekyll-gist
- jekyll-feed
- jekyll-include-cache
