// language=CSS
import { PODKOP_UCI_PACKAGE as PODKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${PODKOP_CBI_PREFIX}-updates-_mount_node > div {
    width: 100%;
}

#cbi-${PODKOP_CBI_PREFIX}-updates > h3 {
    display: none;
}

.pdk_updates-page {
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.pdk_updates-page__top {
    display: grid;
    grid-template-columns: repeat(2, minmax(240px, 1fr));
    grid-gap: 10px;
}

.pdk_updates-page__top .pdk_updates-page__component:first-child {
    border-color: var(--primary-color, #337ab7);
}

@media (max-width: 760px) {
    .pdk_updates-page__top {
        grid-template-columns: 1fr;
    }
}

.pdk_updates-page__components {
    display: grid;
    grid-template-columns: repeat(2, minmax(240px, 1fr));
    grid-gap: 10px;
    max-height: 460px;
    overflow-y: auto;
    padding-right: 4px;
    align-items: start;
}

@media (max-width: 760px) {
    .pdk_updates-page__components {
        grid-template-columns: 1fr;
    }
}

.pdk_updates-page__component {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.pdk_updates-page__component__header {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, auto);
    align-items: start;
    gap: 8px;
    min-width: 0;
}

.pdk_updates-page__component__title {
    color: var(--text-color-high);
    line-height: 1.25;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk_updates-page__component__status {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    min-width: 0;
    max-width: 180px;
    overflow: hidden;
}

.pdk_updates-page__component__meta {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.pdk_updates-page__component__description {
    color: var(--text-color-medium);
    font-size: 12px;
    line-height: 1.4;
}

.pdk_updates-page__component__project-link {
    font-size: 11px;
    color: var(--link-color, #337ab7);
    text-decoration: none;
    align-self: flex-start;
}

.pdk_updates-page__component__project-link:hover {
    text-decoration: underline;
}

.pdk_updates-page__component__version {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-column-gap: 6px;
    align-items: baseline;
    min-width: 0;
}

.pdk_updates-page__component__version__label {
    color: var(--text-color-medium);
}

.pdk_updates-page__component__version__value {
    min-width: 0;
    overflow-wrap: anywhere;
}

.pdk_updates-page__component__tag {
    flex: 0 0 auto;
    padding: 2px 5px;
    border: 1px var(--background-color-high, gray) solid;
    border-radius: 4px;
    color: var(--text-color-medium, gray);
    line-height: 1.2;
}

.pdk_updates-page__component__tag--success {
    border-color: var(--success-color-medium, green);
    color: var(--success-color-medium, green);
}

.pdk_updates-page__component__tag--warning {
    border-color: var(--warn-color-medium, orange);
    color: var(--warn-color-medium, orange);
}

.pdk_updates-page__component__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: auto;
}

.pdk_updates-page__component__actions > .pdk-partial-button {
    margin-left: 0;
}

.pdk_updates-page__component__actions .btn {
    font-size: 13px;
}

.pdk_updates-page__component__actions .btn svg {
    width: 14px;
    height: 14px;
}

.pdk_updates-page__component__release-link {
    display: inline-block;
    flex: 0 1 auto;
    min-width: 0;
    max-width: 100px;
    overflow: hidden;
    font-size: 11px;
    line-height: 1.2;
    text-align: right;
    text-overflow: ellipsis;
    white-space: nowrap;
}
`;
