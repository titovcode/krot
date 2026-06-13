export function preserveScrollForPage(renderFn: () => void) {
  const scrollY = window.scrollY;

  renderFn();

  requestAnimationFrame(() => {
    // Only correct the scroll if our DOM swap actually shifted it. Calling
    // scrollTo unconditionally fights any scrolling the user did in between,
    // which manifests as the page jerking back on every refresh tick.
    if (window.scrollY !== scrollY) {
      window.scrollTo({ top: scrollY });
    }
  });
}
