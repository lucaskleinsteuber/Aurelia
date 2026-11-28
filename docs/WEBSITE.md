# Website

`website/` is Tarven's download page: static HTML, CSS and two JavaScript modules, with no build
step, no framework, no fonts or scripts from elsewhere, no cookies and no tracking. The download
links are filled in the visitor's browser from GitHub's public release list
(`website/releases.mjs`). Without it, every link opens the releases page.

The site is **private**. It is served by Cloudflare Pages behind Cloudflare Access, so only
approved people can open it. Nothing public links to it. Making it public is the owner's
decision.

## Rules

- No personal data: no names, addresses, email addresses or telephone numbers.
- Nothing loaded from another site except the release list from `api.github.com`. `website/_headers`
  enforces this with a Content Security Policy and also asks search engines to stay out.
- The page lists the same downloads as the README, under the same names.

## Checking it

```sh
node --test "tests/Website/*.test.mjs"
python3 -m http.server 8765 --bind 127.0.0.1 --directory website
```

Then open `http://127.0.0.1:8765`.

## Hosting

The Cloudflare Pages project uses `website` as its output directory and has no build command.
Cloudflare Access has to cover every address of the project before the first deployment: the
custom domain, its `www` name, `<project>.pages.dev` and `*.<project>.pages.dev` (the previews).
Its policy allows only the owner's own email address.
