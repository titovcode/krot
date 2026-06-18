// language=CSS
import { PODKOP_UCI_PACKAGE as PODKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${PODKOP_CBI_PREFIX}-dashboard-_mount_node > div {
    width: 100%;
}

#cbi-${PODKOP_CBI_PREFIX}-dashboard-_mount_node.cbi-value {
    display: block;
    margin-bottom: 0;
}

#cbi-${PODKOP_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${PODKOP_CBI_PREFIX}-dashboard-_mount_node > .cbi-value-field {
    margin-left: 0;
    width: 100%;
    min-width: 0;
}

#cbi-${PODKOP_CBI_PREFIX}-dashboard > h3 {
    display: none;
}

.pdk_dashboard-page {
    width: 100%;
    min-width: 0;
}

.pdk_dashboard-page__widgets-section {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 10px;
    flex-wrap: wrap;
    margin-right: 12px;
}

.pdk_dashboard-page__widgets-section > div {
    min-width: 0;
}

.pdk_dashboard-page__widgets-section__item {
    width: 100%;
    min-width: 0;
    min-height: 60px;
    margin: 0;
    box-sizing: border-box;
}

.pdk_dashboard-page__widgets-section__item .ifacebox-body {
    min-width: 0;
    overflow: hidden;
}

.pdk_dashboard-page__widgets-section__item__row {
    display: block;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
}

.pdk_dashboard-page__widgets-section__item__row--success .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--success-color-medium, green);
}

.pdk_dashboard-page__widgets-section__item__row--error .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--error-color-medium, red);
}

#dashboard-sections-grid {
    margin: 10px 0 1em;
    display: grid;
    grid-template-columns: repeat(8, 100px);
    justify-content: space-between;
    align-items: stretch;
    gap: 12px;
    width: 100%;
}

.pdk_dashboard-page__outbound-section {
    display: contents;
}

.pdk_dashboard-page__outbound-section__title-section {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px 10px;
    min-width: 0;
}

.pdk_dashboard-page__outbound-section__title-section__title {
    color: var(--text-color-high);
    font-weight: 700;
    min-width: 0;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page__outbound-section__title-section__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    flex: 0 0 auto;
}

.pdk_dashboard-page .btn.pdk_dashboard-page__outbound-section__subscription-update {
    width: 28px;
    height: 28px;
    min-width: 28px;
    min-height: 28px;
    padding: 2px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    margin: 0;
}

.pdk_dashboard-page__outbound-section__subscription-update svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 auto;
}

.pdk_dashboard-page__outbound-section__subscription-update[disabled] {
    cursor: not-allowed;
    opacity: 0.65;
}

.pdk_dashboard-page__outbound-grid {
    display: contents;
}

.pdk_dashboard-page__subscription-section {
    grid-column: 1 / -1;
    width: 100%;
    margin-top: 10px;
    min-width: 0;
}

.pdk_dashboard-page__subscription-section > h3 {
    margin-top: 0;
}

.pdk_dashboard-page__subscription-table {
    width: 100%;
}

.pdk_dashboard-page__subscription-modal {
    width: 100%;
    max-height: 70vh;
    overflow: auto;
}

.pdk_dashboard-page__subscription-summary-table {
    width: 100%;
}

.pdk_dashboard-page__subscription-table .td {
    vertical-align: middle;
}

.pdk_dashboard-page__subscription-latency-loading {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
}

.pdk_dashboard-page__subscription-latency-loading svg {
    width: 16px;
    height: 16px;
}

.pdk_dashboard-page__subscription-summary-table .td {
    vertical-align: middle;
}

.pdk_dashboard-page__subscription-table .td:first-child,
.pdk_dashboard-page__subscription-summary-table .td:first-child,
.pdk_dashboard-page__subscription-summary-table .td:nth-child(2) {
    overflow-wrap: anywhere;
}

@media (min-width: 900px) {
    .pdk_dashboard-page__subscription-table .td:first-child {
        max-width: 360px;
    }

    .pdk_dashboard-page__subscription-summary-table .td:first-child,
    .pdk_dashboard-page__subscription-summary-table .td:nth-child(2) {
        max-width: 320px;
    }
}

.pdk_dashboard-page__subscription-actions {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    gap: 6px;
}

.pdk_dashboard-page__subscription-actions .cbi-button,
.pdk_dashboard-page__subscription-actions .btn.cbi-button {
    margin: 0;
    box-sizing: border-box;
    min-height: 28px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    vertical-align: middle;
}

.pdk_dashboard-page__subscription-actions .pdk_dashboard-page__subscription-copy-button,
.pdk_dashboard-page__subscription-actions .pdk_dashboard-page__subscription-meta__action,
.pdk_dashboard-page__subscription-actions .pdk_dashboard-page__outbound-section__subscription-update {
    width: 28px;
    min-width: 28px;
    padding: 2px;
}

.pdk_dashboard-page__subscription-actions svg {
    width: 15px;
    height: 15px;
    display: block;
}

.pdk_dashboard-page__monitoring-section {
    margin-top: 18px;
    width: 100%;
}

.pdk_dashboard-page__subscription-meta {
    --subscription-meta-action-size: 28px;
    --subscription-meta-action-gap: 6px;
    flex: 1 1 100%;
    width: 100%;
    padding: 8px 10px;
    box-sizing: border-box;
}

.pdk_dashboard-page__subscription-meta__main {
    display: flex;
    align-items: center;
    gap: 6px 10px;
    min-width: 0;
}

.pdk_dashboard-page__subscription-meta__heading {
    flex: 0 0 auto;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    white-space: nowrap;
}

.pdk_dashboard-page__subscription-meta__title {
    flex: 0 1 auto;
    width: max-content;
    max-width: min(28ch, 30%);
    min-width: min-content;
    color: var(--text-color-high);
    font-weight: 700;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page__subscription-meta__facts {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 5px 12px;
}

.pdk_dashboard-page__subscription-meta__fact {
    display: flex;
    align-items: baseline;
    gap: 4px;
    min-width: 0;
    line-height: 1.25;
}

.pdk_dashboard-page__subscription-meta__fact-key {
    color: var(--text-color-medium);
    font-size: 12px;
    white-space: nowrap;
}

.pdk_dashboard-page__subscription-meta__fact-value {
    color: var(--text-color-high);
    font-weight: 600;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page__subscription-meta__actions {
    flex: 0 0 auto;
    margin-left: auto;
    display: flex;
    justify-content: flex-end;
    gap: var(--subscription-meta-action-gap);
}

.pdk_dashboard-page .btn.pdk_dashboard-page__subscription-meta__action {
    width: var(--subscription-meta-action-size);
    height: var(--subscription-meta-action-size);
    min-width: var(--subscription-meta-action-size);
    min-height: var(--subscription-meta-action-size);
    padding: 2px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
}

.pdk_dashboard-page__subscription-meta__action svg {
    width: 15px;
    height: 15px;
    display: block;
    flex: 0 0 auto;
}

.pdk_dashboard-page__subscription-meta__announce {
    margin: 6px 0 0;
    border-left: 3px solid var(--border-color-high, currentColor);
    padding: 4px 8px;
    color: var(--text-color-medium);
    font-style: italic;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

@media (max-width: 900px) {
    .pdk_dashboard-page__subscription-actions {
        flex-wrap: wrap;
        justify-content: flex-start;
    }

    .pdk_dashboard-page__subscription-meta__main {
        align-items: flex-start;
        flex-wrap: wrap;
    }

    .pdk_dashboard-page__subscription-meta__heading,
    .pdk_dashboard-page__subscription-meta__title {
        order: 1;
    }

    .pdk_dashboard-page__subscription-meta__actions {
        order: 2;
    }

    .pdk_dashboard-page__subscription-meta__facts {
        order: 3;
        flex-basis: 100%;
    }

    .pdk_dashboard-page__subscription-meta__title {
        max-width: calc(100% - 42px);
    }
}

@media (max-width: 700px) {
    .pdk_dashboard-page__widgets-section {
        grid-template-columns: repeat(2, minmax(0, 1fr));
    }

    #dashboard-sections-grid {
        grid-template-columns: repeat(4, 100px);
    }
}

@media (min-width: 701px) and (max-width: 1099px) {
    #dashboard-sections-grid {
        grid-template-columns: repeat(4, 100px);
    }
}

.pdk_dashboard-page__outbound-grid__item {
    position: relative;
    margin: 0;
    width: 100px;
    min-width: 70px;
    max-width: 100px;
    box-sizing: border-box;
}

@media (max-width: 700px) {
    .pdk_dashboard-page__outbound-grid__item {
        width: 100px;
        min-width: 70px;
        max-width: 100px;
    }
}

.pdk_dashboard-page__outbound-grid__item--selectable {
    cursor: pointer;
}

.pdk_dashboard-page__outbound-grid__item--selectable:hover {
    cursor: pointer;
}

.pdk_dashboard-page__outbound-grid__item--disabled {
    cursor: default;
}

.pdk_dashboard-page__outbound-grid__item--switching {
    border-color: transparent !important;
    overflow: hidden;
    cursor: wait;
}

.pdk_dashboard-page__outbound-grid__item__snake {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
    z-index: 9999;
    box-sizing: border-box;
}

.pdk_dashboard-page__outbound-grid__item__snake rect {
    stroke: var(--primary-color-high, dodgerblue);
    stroke-width: 4;
    animation: pdk-dashboard-selector-snake-svg 1.2s linear infinite;
}

@keyframes pdk-dashboard-selector-snake-svg {
    0% {
        stroke-dasharray: 30 70;
        stroke-dashoffset: 100;
    }
    100% {
        stroke-dasharray: 30 70;
        stroke-dashoffset: 0;
    }
}

.pdk_dashboard-page__outbound-grid__item__header {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
}

.pdk_dashboard-page__outbound-grid__item__header b,
.pdk_dashboard-page__outbound-grid__item__header strong {
    min-width: 0;
    line-height: 1.25;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page .btn.pdk_dashboard-page__outbound-grid__item__copy-button {
    width: 18px;
    height: 18px;
    min-width: 18px;
    min-height: 18px;
    padding: 1px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
}

.pdk_dashboard-page__outbound-grid__item__copy-button svg {
    width: 12px;
    height: 12px;
    display: block;
    flex: 0 0 auto;
}

.pdk_dashboard-page__outbound-grid__item__body,
.pdk_dashboard-page__outbound-grid__item .ifacebox-body {
    text-align: center;
}

.pdk_dashboard-page__outbound-grid__item__body img {
    width: 32px;
    height: 32px;
}

.pdk_dashboard-page__outbound-grid__item__status {
    display: flex;
}

.pdk_dashboard-page__outbound-grid__item__stats {
}

.pdk_dashboard-page__outbound-grid__item__name {
    display: inline-block;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk_dashboard-page__outbound-grid__item__type {
    min-width: 0;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page__outbound-grid__item__latency--empty {
    color: var(--primary-color-low, lightgray);
}

.pdk_dashboard-page__outbound-grid__item__latency--green {
    color: var(--success-color-medium, green);
}

.pdk_dashboard-page__outbound-grid__item__latency--yellow {
    color: var(--warn-color-medium, orange);
}

.pdk_dashboard-page__outbound-grid__item__latency--red {
    color: var(--error-color-medium, red);
}

`;
