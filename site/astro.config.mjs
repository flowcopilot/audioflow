// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const repo = 'https://github.com/flowcopilot/audioflow';

export default defineConfig({
  site: 'https://flowcopilot.github.io',
  base: '/audioflow',
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'AudioFlow',
      description: 'An Elixir runtime for voice, image, and video agents.',
      logo: { src: './src/assets/logo.svg', replacesTitle: false },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      editLink: { baseUrl: `${repo}/edit/main/site/` },
      customCss: [
        '@fontsource-variable/bricolage-grotesque/standard.css',
        '@fontsource/ibm-plex-mono/400.css',
        '@fontsource/ibm-plex-mono/600.css',
        './src/styles/docs.css',
      ],
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Introduction', slug: 'docs' },
            { label: 'Quickstart', slug: 'docs/quickstart' },
            { label: 'Chat example', slug: 'docs/chat-example' },
          ],
        },
        {
          label: 'Guides',
          items: [
            'docs/guides/sessions',
            'docs/guides/history',
            'docs/guides/local-models',
            'docs/guides/http-inference',
            'docs/guides/images',
            'docs/guides/video',
            'docs/guides/routing',
            'docs/guides/membrane-input',
            'docs/guides/output',
          ],
        },
        {
          label: 'Validation',
          items: [
            'docs/validation/model-checks',
            'docs/validation/benchmarks',
            'docs/validation/pipecat-comparison',
          ],
        },
      ],
    }),
  ],
});
