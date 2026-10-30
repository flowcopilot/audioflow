# AudioFlow website

The landing page and documentation at https://flowcopilot.github.io/audioflow/.
It uses Astro and Starlight.

```sh
cd site
npm install
npm run dev
```

The landing page is `src/pages/index.astro`. Documentation pages are in
`src/content/docs/docs/`. Add each new page to the sidebar in
`astro.config.mjs`.

The `Website` workflow builds and deploys the site to GitHub Pages after each
push to `main` that changes `site/`.
