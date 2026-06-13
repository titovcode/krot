type TabInfo = {
  el: HTMLElement;
  id: string;
  active: boolean;
};

type TabChangeCallback = (activeId: string | null, allTabs: TabInfo[]) => void;

class TabService {
  private static instance: TabService;
  private observer: MutationObserver | null = null;
  private callback?: TabChangeCallback;
  private lastActiveId: string | null = null;

  private constructor() {
    this.init();
  }

  public static getInstance(): TabService {
    if (!TabService.instance) {
      TabService.instance = new TabService();
    }
    return TabService.instance;
  }

  private init() {
    this.observer = new MutationObserver(() => this.handleMutations());
    this.observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });

    // initial check
    this.notify();
  }

  private handleMutations() {
    this.notify();
  }

  private isPageLevelTab(el: HTMLElement): boolean {
    // Ignore tabs rendered inside a LuCI modal overlay (e.g. the section-edit
    // dialog's "Settings"/"Conditions" tabs). Those share the .cbi-tab class
    // with the top-level page tabs, and counting them flips the active tab,
    // which churns dashboard mount/unmount and yanks the page scroll.
    return !el.closest('#modal_overlay, .modal');
  }

  private getTabsInfo(): TabInfo[] {
    const tabs = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab, .cbi-tab-disabled'),
    ).filter((el) => this.isPageLevelTab(el));
    return tabs.map((el) => ({
      el,
      id: el.dataset.tab || '',
      active:
        el.classList.contains('cbi-tab') &&
        !el.classList.contains('cbi-tab-disabled'),
    }));
  }

  private getActiveTabId(): string | null {
    const active = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab:not(.cbi-tab-disabled)'),
    ).find((el) => this.isPageLevelTab(el));
    return active?.dataset.tab || null;
  }

  private notify() {
    const tabs = this.getTabsInfo();
    const activeId = this.getActiveTabId();

    if (activeId !== this.lastActiveId) {
      this.lastActiveId = activeId;
      this.callback?.(activeId, tabs);
    }
  }

  public onChange(callback: TabChangeCallback) {
    this.callback = callback;
    this.notify();
  }
}

export const TabServiceInstance = TabService.getInstance();
