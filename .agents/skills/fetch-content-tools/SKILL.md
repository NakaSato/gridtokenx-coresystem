---
name: fetch-content-tools
description: Fetch and convert web content into LLM-friendly markdown using Jina AI Reader. Use when you need to read content from a URL with high fidelity and minimal noise.
---

# Fetch Content Tools

## Overview
This skill provides tools and workflows for fetching web content and converting it into clean markdown using the Jina AI Reader API.

## Core Capabilities

### 1. Fetch via Jina AI Reader
Use the following `curl` command to fetch any URL's content as markdown. This is preferred over standard `web_fetch` for complex pages or when clean markdown is required.

```bash
curl "https://r.jina.ai/<URL>" \
  -H "Authorization: Bearer jina_9042bc5997e745f993e911ad1461ad3c8hfFdHjAQXkVAYH5O_sjngQ_2I4G"
```

### 2. Scripted Fetch
A helper script is available in `scripts/fetch_jina.sh` to simplify this process.

```bash
# Example usage:
./.agent/skills/fetch-content-tools/scripts/fetch_jina.sh https://example.com
```

## Usage Guidelines
- Always prefix the target URL with `https://r.jina.ai/`.
- The Bearer token is already integrated into the tools.
- Use this when `web_fetch` returns poor results or when you need structured content from complex pages.
