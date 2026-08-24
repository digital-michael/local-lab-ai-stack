// Rewrites LAN (*.stack.localhost) service links to their public (*.photondatum.space)
// equivalents when the dashboard itself is being viewed via dashboard.photondatum.space.
// The server renders the same HTML regardless of viewer origin, so this has to happen
// client-side — only the browser knows which hostname it used to reach the page.
(function () {
  var PUBLIC_DASHBOARD_HOSTS = ["dashboard.photondatum.space"];
  var HOST_MAP = {
    "openwebui.stack.localhost": "agent.photondatum.space",
    "flowise.stack.localhost": "flowise.photondatum.space",
    "litellm.stack.localhost": "litellm.photondatum.space",
    "ki.stack.localhost": "ki.photondatum.space",
    "grafana.stack.localhost": "grafana.photondatum.space",
    "prometheus.stack.localhost": "prometheus.photondatum.space",
  };

  function isRemoteView() {
    return PUBLIC_DASHBOARD_HOSTS.indexOf(window.location.hostname) !== -1;
  }

  function rewriteLinks() {
    if (!isRemoteView()) return;
    document.querySelectorAll("a[href]").forEach(function (a) {
      try {
        var url = new URL(a.href, window.location.href);
        var replacement = HOST_MAP[url.hostname];
        if (replacement && url.hostname !== replacement) {
          url.hostname = replacement;
          a.href = url.toString();
        }
      } catch (e) {
        // malformed/relative href — leave untouched
      }
    });
  }

  rewriteLinks();
  new MutationObserver(rewriteLinks).observe(document.body, {
    childList: true,
    subtree: true,
  });
})();
