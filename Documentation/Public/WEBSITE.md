# Website preview and hosting

The static site in `Website/` has a German root page and an English page under `en/`. It uses local CSS and images, with no JavaScript, analytics or external fonts.

Preview it from the repository root.

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Website
```

For a Cloudflare Pages deployment, use `Website/` as the static output folder. Keep the language directories and `_headers`. Check the required provider and privacy disclosures for the actual operator and hosting configuration before go-live. After deployment, verify both language routes, the GitHub links, and the response headers. [Cloudflare Pages static HTML guide](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/)
