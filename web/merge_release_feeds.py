#!/usr/bin/env python3
"""Merge GitHub Release Feeds

Auto-discovers starred repos and star list categories from GitHub,
fetches release feeds, and generates combined + per-category Atom feeds.

Output: _site/feeds/*.atom + _site/index.html
"""

import copy
import html
import json
import os
import re
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from http.client import IncompleteRead
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET

GITHUB_USERNAME = "bikram-agarwal"
PAGES_BASE_URL = f"https://{GITHUB_USERNAME}.github.io/AWWsome-Toolkit/feeds"
ATOM_NS = "http://www.w3.org/2005/Atom"
MAX_ENTRIES_PER_CATEGORY = 200
MAX_ENTRIES_ALL = 300
FEED_FETCH_WORKERS = 20
RELEASES_PAGE_SIZE = 50
RELEASES_PAGES_PER_REPO = 1
GITHUB_API_RETRIES = 3
GITHUB_API_RETRY_DELAY_SEC = 2
RETRYABLE_HTTP_CODES = (429, 500, 502, 503, 504)
SITE_DIR = Path("_site")
OUTPUT_DIR = SITE_DIR / "feeds"
GITHUB_STARS_LOGO = Path("web/Github_Stars.webp")
RELEASE_FEEDS_PAGE_URL = f"https://{GITHUB_USERNAME}.github.io/AWWsome-Toolkit/"
RELEASE_FEEDS_TITLE = "GitHub Stars Release Feeds"
RELEASE_FEEDS_DESCRIPTION = (
    "Curated Atom release feeds for useful open-source projects from "
    f"{GITHUB_USERNAME}'s starred GitHub repositories."
)
RELEASE_FEEDS_IMAGE_URL = f"{RELEASE_FEEDS_PAGE_URL}{GITHUB_STARS_LOGO.name}"

ET.register_namespace("", ATOM_NS)


def github_api_get(url):
    """Fetch a GitHub API endpoint, using GITHUB_TOKEN for higher rate limits.
    Retries on transient errors: IncompleteRead, connection/timeout errors,
    and HTTP 429/5xx.
    """
    headers = {
        "Accept": "application/vnd.github.v3.html+json",
        "User-Agent": "merge-release-feeds",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"token {token}"
    last_error = None
    for attempt in range(GITHUB_API_RETRIES):
        try:
            with urlopen(Request(url, headers=headers), timeout=30) as response:
                return json.loads(response.read().decode())
        except HTTPError as err:
            last_error = err
            if err.code in RETRYABLE_HTTP_CODES and attempt < GITHUB_API_RETRIES - 1:
                time.sleep(GITHUB_API_RETRY_DELAY_SEC)
            else:
                raise last_error
        except (IncompleteRead, URLError, ConnectionError, TimeoutError) as err:
            last_error = err
            if attempt < GITHUB_API_RETRIES - 1:
                time.sleep(GITHUB_API_RETRY_DELAY_SEC)
            else:
                raise last_error


def web_get(url):
    """Fetch a URL and return the response body as text."""
    with urlopen(
        Request(url, headers={"User-Agent": "merge-release-feeds"}), timeout=30
    ) as response:
        return response.read().decode()


def fetch_starred_repos():
    """Fetch all starred repo full_names via the GitHub API (handles pagination)."""
    repos = []
    page = 1
    while True:
        api_url = (
            f"https://api.github.com/users/{GITHUB_USERNAME}"
            f"/starred?per_page=100&page={page}"
        )
        print(f"  Fetching starred repos (page {page})...")
        batch = github_api_get(api_url)
        if not batch:
            break
        repos.extend(entry["full_name"] for entry in batch)
        if len(batch) < 100:
            break
        page += 1
    return repos


def discover_lists_and_repos(starred_set):
    """Discover star lists from the profile page, then fetch each list page
    to determine which starred repos belong to which category.

    Returns dict: {slug: {"name": display_name, "repos": [repo, ...]}}
    """
    print("  Fetching stars page to discover lists...")
    stars_html = web_get(f"https://github.com/{GITHUB_USERNAME}?tab=stars")

    slug_pattern = rf"/stars/{re.escape(GITHUB_USERNAME)}/lists/([a-z0-9_-]+)"
    slugs = list(dict.fromkeys(re.findall(slug_pattern, stars_html)))

    categories = {}
    for slug in slugs:
        display_name = slug.replace("-", " ").title()
        name_pattern = (
            rf'href="/stars/{re.escape(GITHUB_USERNAME)}/lists/{re.escape(slug)}'
            rf'"[^>]*>\s*([^<]+)'
        )
        name_match = re.search(name_pattern, stars_html)
        if name_match and name_match.group(1).strip():
            display_name = name_match.group(1).strip()

        print(f"  Fetching list '{display_name}'...")
        repos_in_list = set()
        page_num = 1
        while True:
            list_url = (
                f"https://github.com/stars/{GITHUB_USERNAME}"
                f"/lists/{slug}?page={page_num}"
            )
            try:
                list_html = web_get(list_url)
            except (HTTPError, URLError):
                break

            repo_hrefs = re.findall(
                r'href="/([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)"', list_html
            )
            new_repos = {href for href in repo_hrefs if href in starred_set}
            new_repos -= repos_in_list
            if not new_repos:
                break

            repos_in_list.update(new_repos)
            if f"page={page_num + 1}" not in list_html:
                break
            page_num += 1

        categories[slug] = {"name": display_name, "repos": sorted(repos_in_list)}
        print(f"    {len(repos_in_list)} repos")

    return categories


def fetch_releases_api(repo):
    """Fetch recent releases for a repo via GitHub API (releases only, no tag-only).
    Only fetches the first N pages (newest first) to avoid scanning hundreds of
    releases per repo. Returns (repo, list of release dicts).
    """
    releases = []
    try:
        for page in range(1, RELEASES_PAGES_PER_REPO + 1):
            api_url = (
                f"https://api.github.com/repos/{repo}/releases"
                f"?per_page={RELEASES_PAGE_SIZE}&page={page}"
            )
            batch = github_api_get(api_url)
            if not batch:
                break
            releases.extend(batch)
            if len(batch) < RELEASES_PAGE_SIZE:
                break
    except (
        HTTPError,
        URLError,
        IncompleteRead,
        ConnectionError,
        TimeoutError,
    ) as err:
        print(f"    Warning: {repo} - {err}")
        return repo, []
    return repo, releases


def release_to_atom_entry(repo, release):
    """Build one Atom <entry> Element from a GitHub API release dict."""
    entry = ET.Element(f"{{{ATOM_NS}}}entry")
    tag_name = release.get("tag_name", "")
    html_url = release.get("html_url", f"https://github.com/{repo}/releases/tag/{tag_name}")
    node_id = release.get("node_id", "")
    entry_id = f"tag:github.com,2008:Repository/{node_id}/{tag_name}" if node_id else html_url
    ET.SubElement(entry, f"{{{ATOM_NS}}}id").text = entry_id
    updated = release.get("published_at") or release.get("created_at", "")
    if updated:
        ET.SubElement(entry, f"{{{ATOM_NS}}}updated").text = updated
    link = ET.SubElement(entry, f"{{{ATOM_NS}}}link")
    link.set("rel", "alternate")
    link.set("type", "text/html")
    link.set("href", html_url)
    title = release.get("name") or tag_name
    ET.SubElement(entry, f"{{{ATOM_NS}}}title").text = f"{repo}: {title}"
    body_html = release.get("body_html") or ""
    if not body_html and release.get("body"):
        body_html = f"<p>{html.escape(release['body'])}</p>"

    repo_page_url = f"https://github.com/{repo}"
    metadata_parts = [
        f'<a href="{html.escape(repo_page_url, quote=True)}">'
        f"Repository: {html.escape(repo)}</a>"
    ]
    if tag_name:
        tag_page_url = (
            f"https://github.com/{repo}/releases/tag/{quote(tag_name, safe='')}"
        )
        metadata_parts.append(
            f'<a href="{html.escape(tag_page_url, quote=True)}">'
            f"Tag: {html.escape(tag_name)}</a>"
        )
    target_commitish = release.get("target_commitish") or ""
    if target_commitish:
        if re.fullmatch(r"[0-9a-f]{7,40}", target_commitish, re.IGNORECASE):
            commit_url = f"https://github.com/{repo}/commit/{target_commitish}"
            metadata_parts.append(
                f'<a href="{html.escape(commit_url, quote=True)}">'
                f"Commit: {html.escape(target_commitish)}</a>"
            )
        else:
            metadata_parts.append(f"Commit: {html.escape(target_commitish)}")
    author_dict = release.get("author") if isinstance(release.get("author"), dict) else None
    if author_dict:
        author_login = author_dict.get("login") or ""
        author_profile_url = author_dict.get("html_url") or ""
        if author_login and author_profile_url:
            metadata_parts.append(
                "Released by: "
                f'<a href="{html.escape(author_profile_url, quote=True)}">'
                f"{html.escape(author_login)}</a>"
            )
        elif author_login:
            metadata_parts.append(f"Released by: {html.escape(author_login)}")
    metadata_html = "<p>" + " · ".join(metadata_parts) + "</p><hr />"

    uploaded_assets = release.get("assets") or []
    zipball_url = release.get("zipball_url") or ""
    tarball_url = release.get("tarball_url") or ""
    asset_count = len(uploaded_assets) + (1 if zipball_url else 0) + (1 if tarball_url else 0)
    assets_suffix_html = ""
    if asset_count:
        list_items_html = []
        for asset in uploaded_assets:
            asset_name = asset.get("name") or "asset"
            download_url = asset.get("browser_download_url") or ""
            if download_url:
                list_items_html.append(
                    f'<li><a href="{html.escape(download_url, quote=True)}">'
                    f"{html.escape(asset_name)}</a></li>"
                )
            else:
                list_items_html.append(f"<li>{html.escape(asset_name)}</li>")
        if zipball_url:
            list_items_html.append(
                f'<li><a href="{html.escape(zipball_url, quote=True)}">'
                "Source code (zip)</a></li>"
            )
        if tarball_url:
            list_items_html.append(
                f'<li><a href="{html.escape(tarball_url, quote=True)}">'
                "Source code (tar.gz)</a></li>"
            )
        asset_word = "asset" if asset_count == 1 else "assets"
        assets_suffix_html = (
            "<hr /><p>"
            f"This release has {asset_count} {asset_word}:</p><ul>"
            + "".join(list_items_html)
            + "</ul><p>"
            f'<a href="{html.escape(html_url, quote=True)}">Visit the release page</a> '
            "to download them.</p>"
        )

    content_elem = ET.SubElement(entry, f"{{{ATOM_NS}}}content")
    content_elem.set("type", "html")
    content_elem.text = metadata_html + body_html + assets_suffix_html
    author = ET.SubElement(entry, f"{{{ATOM_NS}}}author")
    author_login = "unknown"
    if release.get("author") and isinstance(release["author"], dict):
        author_login = release["author"].get("login", author_login)
    ET.SubElement(author, f"{{{ATOM_NS}}}name").text = author_login
    return entry


def releases_to_entries(repo, releases):
    """Convert API release list to Atom entry Elements with repo-prefixed titles."""
    return [release_to_atom_entry(repo, release) for release in releases]


def entry_updated_key(entry):
    """Sort key: extract <updated> text from an Atom entry."""
    updated_elem = entry.find(f"{{{ATOM_NS}}}updated")
    if updated_elem is not None and updated_elem.text:
        return updated_elem.text
    return ""


def build_atom_feed(title, self_url, entries):
    """Build a complete Atom feed XML string from entry Elements."""
    feed = ET.Element(f"{{{ATOM_NS}}}feed")
    ET.SubElement(feed, f"{{{ATOM_NS}}}title").text = title
    ET.SubElement(feed, f"{{{ATOM_NS}}}id").text = self_url
    self_link = ET.SubElement(feed, f"{{{ATOM_NS}}}link")
    self_link.set("rel", "self")
    self_link.set("href", self_url)
    ET.SubElement(feed, f"{{{ATOM_NS}}}updated").text = datetime.now(
        timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    author = ET.SubElement(feed, f"{{{ATOM_NS}}}author")
    ET.SubElement(author, f"{{{ATOM_NS}}}name").text = GITHUB_USERNAME

    for entry in entries:
        feed.append(copy.deepcopy(entry))

    ET.indent(feed, space="  ")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(
        feed, encoding="unicode"
    )


def write_feed(filename, title, entries, max_entries):
    """Sort entries by date, cap at max_entries, and write an Atom feed to disk."""
    sorted_entries = sorted(entries, key=entry_updated_key, reverse=True)[:max_entries]
    self_url = f"{PAGES_BASE_URL}/{filename}"
    xml_output = build_atom_feed(title, self_url, sorted_entries)
    (OUTPUT_DIR / filename).write_text(xml_output, encoding="utf-8")
    return len(sorted_entries)


def build_feed_preview_items(entries):
    """Return compact display titles for the newest entries in a feed card."""
    preview_entries = sorted(entries, key=entry_updated_key, reverse=True)[:3]
    preview_items = []
    for entry in preview_entries:
        title_elem = entry.find(f"{{{ATOM_NS}}}title")
        title_text = title_elem.text if title_elem is not None and title_elem.text else ""
        repo_text, separator_text, release_title = title_text.partition(": ")
        if separator_text:
            repo_name = repo_text.rsplit("/", 1)[-1]
            preview_text = f"{repo_name} - {release_title}"
        else:
            preview_text = title_text.rsplit("/", 1)[-1]
        if preview_text:
            preview_items.append(preview_text)
    return preview_items


def render_feed_preview(preview_items):
    """Render the latest entries panel for a feed card."""
    display_items = preview_items or ["No releases found yet"]
    preview_rows = "\n".join(
        f"            <li><span>{html.escape(preview_item)}</span></li>"
        for preview_item in display_items
    )
    return (
        "        <div class=\"feed-preview-box\">\n"
        "          <div class=\"feed-preview-header\">Latest Entries</div>\n"
        "          <ul class=\"feed-preview-list\">\n"
        f"{preview_rows}\n"
        "          </ul>\n"
        "        </div>"
    )


def render_feed_card(feed_info_entry, is_all_releases=False):
    """Render one feed card for the generated index page."""
    feed_filename, label, repo_count, entry_count, preview_items = feed_info_entry
    card_class = "feature-card all-releases-card" if is_all_releases else "feature-card"
    return (
        f"      <article class=\"{card_class}\">\n"
        "        <div>\n"
        f"          <h3>{html.escape(label)}</h3>\n"
        "          <div class=\"chip-row\" aria-label=\"Feed size\">\n"
        f"            <span class=\"meta-chip\">{repo_count} repos</span>\n"
        f"            <span class=\"meta-chip\">{entry_count} entries</span>\n"
        "          </div>\n"
        "          <div class=\"feed-action-row\">\n"
        "            <button class=\"meta-chip feed-action\" type=\"button\" "
        f"data-feed-url=\"{html.escape(PAGES_BASE_URL + '/' + feed_filename, quote=True)}\">"
        "Copy Feed URL</button>\n"
        "          </div>\n"
        "        </div>\n"
        f"{render_feed_preview(preview_items)}\n"
        "      </article>"
    )


def generate_index_html(feed_info):
    """Generate _site/index.html listing all available feeds."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    all_release_feeds = [feed for feed in feed_info if feed[1] == "All Releases"]
    display_feed_info = [feed for feed in feed_info if feed[1] != "All Releases"]
    my_project_feeds = [feed for feed in display_feed_info if feed[1] == "My Projects"]
    uncategorized_feeds = [
        feed for feed in display_feed_info if feed[1] == "Uncategorized"
    ]
    display_feed_info = [
        feed
        for feed in display_feed_info
        if feed[1] not in ("My Projects", "Uncategorized")
    ]
    windows_index = next(
        (
            feed_index
            for feed_index, feed in enumerate(display_feed_info)
            if feed[1] == "Windows Apps"
        ),
        None,
    )
    if uncategorized_feeds:
        if windows_index is None:
            display_feed_info.extend(uncategorized_feeds)
        else:
            display_feed_info[windows_index + 1 : windows_index + 1] = uncategorized_feeds
    display_feed_info = my_project_feeds + display_feed_info

    all_release_cards = "\n".join(
        render_feed_card(feed, is_all_releases=True) for feed in all_release_feeds
    )
    category_feed_cards = "\n".join(render_feed_card(feed) for feed in display_feed_info)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{RELEASE_FEEDS_TITLE}</title>
  <meta name="description" content="{RELEASE_FEEDS_DESCRIPTION}">
  <link rel="canonical" href="{RELEASE_FEEDS_PAGE_URL}">
  <link rel="icon" type="image/webp" href="Github_Stars.webp">
  <link rel="apple-touch-icon" href="Github_Stars.webp">
  <meta property="og:type" content="website">
  <meta property="og:title" content="{RELEASE_FEEDS_TITLE}">
  <meta property="og:description" content="{RELEASE_FEEDS_DESCRIPTION}">
  <meta property="og:url" content="{RELEASE_FEEDS_PAGE_URL}">
  <meta property="og:image" content="{RELEASE_FEEDS_IMAGE_URL}">
  <meta name="twitter:card" content="summary">
  <meta name="twitter:title" content="{RELEASE_FEEDS_TITLE}">
  <meta name="twitter:description" content="{RELEASE_FEEDS_DESCRIPTION}">
  <meta name="twitter:image" content="{RELEASE_FEEDS_IMAGE_URL}">
  <link rel="stylesheet" href="https://bikram-agarwal.github.io/assets/style.css?v=3-20260512">
  <script src="https://bikram-agarwal.github.io/assets/site.js?v=3-20260512" defer></script>
  <script type="application/ld+json">
    {{
      "@context": "https://schema.org",
      "@type": "CreativeWork",
      "name": "{RELEASE_FEEDS_TITLE}",
      "description": "{RELEASE_FEEDS_DESCRIPTION}",
      "url": "{RELEASE_FEEDS_PAGE_URL}",
      "image": "{RELEASE_FEEDS_IMAGE_URL}",
      "author": {{
        "@type": "Person",
        "name": "Bikram Agarwal",
        "url": "https://bikram-agarwal.github.io/"
      }}
    }}
  </script>
</head>
<body class="theme-awwsome">
  <main class="site-shell">
    <nav class="nav page-nav desktop-site-nav" aria-label="Site">
      <a class="pill" href="../">Home</a>
      <a class="pill" href="../remember/">Remember</a>
      <a class="pill" href="../filepipe/">FilePipe</a>
      <a class="pill" href="../obtainx/">ObtainX</a>
      <a class="pill" href="../awwsome-toolkit/">AWWsome Toolkit</a>
      <a class="pill" href="../archive/">Archive</a>
    </nav>
    <details class="mobile-site-menu">
      <summary aria-label="Open site navigation">
        <span class="menu-icon" aria-hidden="true"><span></span><span></span><span></span></span>
      </summary>
      <div class="mobile-menu-panel">
        <nav class="mobile-menu-links" aria-label="Site menu">
          <a href="../">Home</a>
          <a href="../remember/">Remember</a>
          <a href="../filepipe/">FilePipe</a>
          <a href="../obtainx/">ObtainX</a>
          <a href="../awwsome-toolkit/" aria-current="location">AWWsome Toolkit</a>
          <a href="../archive/">Archive</a>
        </nav>
      </div>
    </details>

    <section class="hero project-hero">
      <div class="hero-media">
        <img class="app-logo" src="Github_Stars.webp" alt="GitHub Stars logo">
        <nav class="nav" aria-label="GitHub Stars links">
          <a class="pill primary" href="https://github.com/{GITHUB_USERNAME}/AWWsome-Toolkit/blob/main/web/merge_release_feeds.py" target="_blank" rel="noopener"><img class="pill-icon" src="https://bikram-agarwal.github.io/assets/fav_github.ico" alt="" aria-hidden="true">Source on GitHub</a>
          <a class="pill secondary-strong" href="https://github.com/{GITHUB_USERNAME}?tab=stars" target="_blank" rel="noopener">⭐ GitHub Stars</a>
          <a class="pill" href="../awwsome-toolkit/privacy/">Privacy</a>
          <a class="pill" href="../awwsome-toolkit/terms/">Terms</a>
        </nav>
      </div>
      <div class="hero-copy">
        <h1>Release Feeds</h1>
        <div class="chip-row" aria-label="Feed type">
          <span class="meta-chip">Android</span>
          <span class="meta-chip">Windows</span>
          <span class="meta-chip">Web</span>
        </div>
        <p class="lede">
          These feeds are curated release alerts for useful open-source projects across Android apps, rooting tools, ReVanced/Morphe patches, Windows software, and more. If you want category-based updates from the projects I actively track, without subscribing to dozens of repos individually, these feeds give you a clean, high-signal way to stay current.
        </p>
        <section class="content-card">
          <h2>Why It Exists</h2>
          <p>GitHub notifications were never built for tracking releases. They mixed issues, PRs, mentions, and discussions with the few updates I actually cared about, so I kept missing new versions of the projects I follow. I built this feed generator to fix that. It pulls release events from my starred repos, groups them by the lists I already maintain, and turns them into clean Atom feeds I can read in a normal feed reader.</p>
        </section>
      </div>
    </section>

    <div class="feed-info-bar" role="note"><strong>How to use:</strong> Copy a feed URL &rarr; Paste into your RSS reader &rarr; Stay updated.</div>

    <section class="feature-grid feed-grid" aria-label="Available feeds">
{all_release_cards}
{category_feed_cards}
    </section>

    <footer class="site-footer feed-footer">
      <span>Made with ❤️ by <a href="https://bikram-agarwal.github.io/">Bikram Agarwal</a></span>
      <span class="feed-footer-updated">Last updated: {timestamp}</span>
    </footer>
  </main>
  <script>
    document.querySelectorAll("[data-feed-url]").forEach((feedButton) => {{
      const defaultLabel = feedButton.textContent;
      feedButton.addEventListener("click", async () => {{
        const feedUrl = feedButton.dataset.feedUrl;
        try {{
          await navigator.clipboard.writeText(feedUrl);
          feedButton.textContent = "Copied!";
          window.setTimeout(() => {{
            feedButton.textContent = defaultLabel;
          }}, 1600);
        }} catch {{
          window.prompt("Copy this feed URL:", feedUrl);
        }}
      }});
    }});
  </script>
</body>
</html>"""


def main():
    print("=== Step 1: Discover starred repos ===")
    starred_repos = fetch_starred_repos()
    if not starred_repos:
        print("Error: No starred repos found.")
        sys.exit(1)
    print(f"  Total: {len(starred_repos)} starred repos\n")
    starred_set = set(starred_repos)

    print("=== Step 2: Discover star list categories ===")
    categories = discover_lists_and_repos(starred_set)

    categorized_repos = set()
    for info in categories.values():
        categorized_repos.update(info["repos"])

    uncategorized_repos = [repo for repo in starred_repos if repo not in categorized_repos]
    if uncategorized_repos:
        categories["uncategorized"] = {"name": "Uncategorized", "repos": uncategorized_repos}
    print(f"  {len(uncategorized_repos)} uncategorized repos\n")

    print(f"=== Step 3: Fetch releases via API ({len(starred_repos)} repos) ===")
    repo_entries = {}
    with ThreadPoolExecutor(max_workers=FEED_FETCH_WORKERS) as pool:
        futures = {
            pool.submit(fetch_releases_api, repo): repo for repo in starred_repos
        }
        for future in as_completed(futures):
            repo, releases = future.result()
            repo_entries[repo] = releases_to_entries(repo, releases)

    total_entries = sum(len(entry_list) for entry_list in repo_entries.values())
    print(f"  Parsed {total_entries} entries total\n")

    print("=== Step 4: Generate feeds ===")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(GITHUB_STARS_LOGO, SITE_DIR / GITHUB_STARS_LOGO.name)
    feed_info = []

    all_entries = [entry for entry_list in repo_entries.values() for entry in entry_list]
    entry_count = write_feed(
        "all.atom", "GitHub Stars - All Releases", all_entries, MAX_ENTRIES_ALL
    )
    feed_info.append(
        (
            "all.atom",
            "All Releases",
            len(starred_repos),
            entry_count,
            build_feed_preview_items(all_entries),
        )
    )
    print(f"  all.atom: {entry_count} entries from {len(starred_repos)} repos")

    for slug in sorted(categories):
        info = categories[slug]
        cat_entries = [
            entry
            for repo in info["repos"]
            for entry in repo_entries.get(repo, [])
        ]
        entry_count = write_feed(
            f"{slug}.atom",
            f"GitHub Stars - {info['name']}",
            cat_entries,
            MAX_ENTRIES_PER_CATEGORY,
        )
        feed_info.append(
            (
                f"{slug}.atom",
                info["name"],
                len(info["repos"]),
                entry_count,
                build_feed_preview_items(cat_entries),
            )
        )
        print(f"  {slug}.atom: {entry_count} entries from {len(info['repos'])} repos")

    (SITE_DIR / "index.html").write_text(
        generate_index_html(feed_info), encoding="utf-8"
    )
    print(f"\n  index.html generated")
    print(f"\nDone! {len(feed_info)} feeds written to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
