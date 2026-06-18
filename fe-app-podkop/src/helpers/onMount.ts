function getTarget(target: string | HTMLElement): HTMLElement | null {
  if (typeof target === 'string') {
    return document.getElementById(target);
  }

  return target;
}

export async function onMount(
  target: string | HTMLElement,
  timeoutMs = 10000,
): Promise<HTMLElement> {
  return new Promise((resolve) => {
    let observer: MutationObserver | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const cleanup = () => {
      observer?.disconnect();
      observer = null;
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    };

    const resolveIfMountedAndVisible = () => {
      const mountedTarget = getTarget(target);

      if (
        mountedTarget &&
        mountedTarget.isConnected &&
        mountedTarget.offsetParent !== null
      ) {
        cleanup();
        resolve(mountedTarget);
        return true;
      }

      return false;
    };

    if (resolveIfMountedAndVisible()) {
      return;
    }

    timer = setTimeout(() => {
      cleanup();
    }, timeoutMs);

    observer = new MutationObserver(() => {
      resolveIfMountedAndVisible();
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style', 'hidden'],
    });
  });
}
