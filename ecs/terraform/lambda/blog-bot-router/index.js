'use strict';

// CloudFront Lambda@Edge origin-request trigger for the marketing distribution's
// /blog* cache behavior (see marketing.tf). Social/search bots requesting a blog
// URL are routed to the wrapper backend (which server-renders og:title/og:image/
// etc. for link previews); everything else falls through to the default S3
// origin unchanged, so humans keep getting the normal SPA.
//
// Bot list ported from backend/src/features/blog/crawler.ts's isCrawler() -
// keep both in sync if the list changes.
const CRAWLER_RE = new RegExp(
  [
    // search engines
    'googlebot', 'google-inspectiontool', 'google-extended', 'bingbot', 'slurp',
    'duckduckbot', 'baiduspider', 'yandex', 'sogou', 'exabot', 'applebot',
    // social / link unfurlers
    'facebookexternalhit', 'facebot', 'twitterbot', 'slackbot', 'slack-imgproxy',
    'discordbot', 'linkedinbot', 'whatsapp', 'telegrambot', 'pinterest',
    'redditbot', 'embedly', 'quora link preview', 'skypeuripreview', 'vkshare',
    'bitlybot', 'nuzzel', 'flipboard',
    // AI crawlers
    'gptbot', 'chatgpt-user', 'oai-searchbot', 'claudebot', 'claude-web',
    'anthropic-ai', 'perplexitybot', 'amazonbot', 'bytespider', 'ccbot', 'cohere-ai',
  ].join('|'),
  'i',
);

const API_DOMAIN = 'api.zopkit.com';

exports.handler = (event, context, callback) => {
  const request = event.Records[0].cf.request;
  const uaHeader = request.headers['user-agent'];
  const ua = (uaHeader && uaHeader[0] && uaHeader[0].value) || '';
  const isBot = CRAWLER_RE.test(ua);
  console.log(JSON.stringify({ uri: request.uri, ua, isBot, originBefore: request.origin }));

  if (isBot) {
    request.origin = {
      custom: {
        domainName: API_DOMAIN,
        port: 443,
        protocol: 'https',
        path: '',
        sslProtocols: ['TLSv1.2'],
        readTimeout: 30,
        keepaliveTimeout: 5,
        customHeaders: {},
      },
    };
    // The ALB's host-header listener rule for wrapper-web only matches
    // api.zopkit.com — without this the viewer's real Host (www.zopkit.com)
    // would reach the ALB and hit its default 404 fixed-response.
    request.headers['host'] = [{ key: 'Host', value: API_DOMAIN }];
  }

  console.log(JSON.stringify({ originAfter: request.origin, headersAfter: request.headers['host'] }));
  callback(null, request);
};
