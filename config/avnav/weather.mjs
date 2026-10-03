export const apiBase = () => {
    const origin = new URL(window.location.origin);
    if (origin.port === '8088') origin.port = '80';
    return new URL('/wxapi/', origin).href;
};

export async function request(endpoint, values = {}) {
    const url = new URL(endpoint, apiBase());
    Object.entries(values).forEach(([key, value]) => url.searchParams.set(key, value));
    const response = await fetch(url, {signal: AbortSignal.timeout(10000)});
    const body = await response.json();
    if (!response.ok) throw new Error(body.error || `Weather HTTP ${response.status}`);
    return body;
}

export const escape = value => String(value).replace(/[&<>"']/g, character =>
    ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[character]));

export function selection(meta) {
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('seabird-weather') || '{}'); } catch (_) {}
    const layers = Object.keys(meta.products);
    const layer = layers.includes(saved.layer) ? saved.layer : layers[0];
    const times = meta.products[layer]?.times || [];
    const time = times.includes(saved.time) ? saved.time :
        (times.find(value => Date.parse(value) >= Date.now()) || times[times.length - 1]);
    return {layer, time, enabled: saved.enabled !== false};
}

export function saveSelection(value) {
    localStorage.setItem('seabird-weather', JSON.stringify(value));
    window.dispatchEvent(new Event('seabird-weather-change'));
}

export function passageSelection() {
    try { return JSON.parse(localStorage.getItem('seabird-passage') || 'null'); }
    catch (_) { return null; }
}

export function savePassage(value) {
    if (value) localStorage.setItem('seabird-passage', JSON.stringify(value));
    else localStorage.removeItem('seabird-passage');
    window.dispatchEvent(new Event('seabird-weather-change'));
}

export async function openWeatherChart() {
    const url = new URL('/api?request=download&type=layout&name=user.weather', window.location.origin);
    const response = await fetch(url);
    if (!response.ok) throw new Error('Weather layout unavailable');
    const layout = await response.json();
    if (layout.layoutVersion !== 1 || !layout.widgets?.navpage?.overlay) throw new Error('Invalid weather layout');
    const settings = JSON.parse(localStorage.getItem('avnav.settings') || '{}');
    localStorage.setItem('avnav.settings', JSON.stringify({...settings, layoutName: 'user.weather'}));
    localStorage.setItem('avnav.layout', JSON.stringify({name: 'user.weather', data: layout}));
    window.location.assign(new URL('/avnav/viewer/avnav_viewer.html', window.location.origin).href);
}

export function summary(products) {
    const number = value => Number.isFinite(value) ? value.toFixed(1) : '--';
    const wind = products.wind, waves = products.waves, currents = products.currents;
    return `Wind ${number(wind?.speed_kn)} kn from ${number(wind?.direction_deg)} deg | ` +
        `Waves ${number(waves?.height_m)} m from ${number(waves?.direction_deg)} deg | ` +
        `Current ${number(currents?.speed_kn)} kn to ${number(currents?.direction_deg)} deg`;
}

export default function install(api) {
    const contexts = new Set();
    let state = {error: 'Loading forecast'}, features = [], serial = 0;
    const style = document.createElement('style');
    style.textContent = `
        .widgetContainer.horizontal.top:has(> .userWeatherForecast) {
            width: fit-content; max-width: 100%; height: auto !important;
            align-items: flex-start;
        }
        .widget.userWeatherForecast {
            flex: 0 1 auto !important; width: max-content !important;
            max-width: min(38rem, 100%); height: auto !important;
            min-width: 0; align-self: flex-start;
        }
        .widget.userWeatherForecast > .noresize {
            display: block; height: auto !important; min-height: 0;
        }
        .seabird-weather-controller {
            padding: 6px; white-space: normal; font-size: 14px;
            line-height: 1.4; overflow-wrap: anywhere;
        }
        .seabird-weather-controller select { max-width: 100%; }
    `;
    document.head.append(style);
    const inputEvents = ['pointerdown', 'pointerup', 'mousedown', 'mouseup',
        'touchstart', 'touchend', 'click', 'dblclick', 'wheel', 'keydown', 'keyup', 'change'];
    const handleInput = event => {
        if (!event.target.closest?.('.seabird-weather-controller')) return;
        event.stopPropagation();
        if (event.type !== 'change' || !state.choice) return;
        const action = event.target.dataset.weatherAction;
        if (action === 'time') saveSelection({...state.choice, time: event.target.value});
        if (action === 'layer') saveSelection({...state.choice, layer: event.target.value, time: undefined});
        if (action === 'enabled') saveSelection({...state.choice, enabled: event.target.checked});
    };
    inputEvents.forEach(name => document.addEventListener(name, handleInput, {capture: true, passive: true}));
    const redraw = () => contexts.forEach(context => {
        if (context.triggerRedraw) context.triggerRedraw();
        else if (context.triggerRender) context.triggerRender();
    });
    async function refresh() {
        const ticket = ++serial;
        try {
            const meta = await request('meta');
            const choice = selection(meta);
            const data = await request('overlay', {time: choice.time, layer: choice.layer});
            let point, pointError;
            try { point = await request('point', {time: choice.time}); }
            catch (error) { pointError = error.message; }
            const planned = passageSelection();
            let passage, passageError;
            if (planned) {
                try { passage = await request('route', planned); }
                catch (error) { passageError = error.message; }
            }
            if (ticket !== serial) return;
            state = {meta, choice, point, pointError, planned, passage, passageError};
            features = choice.enabled ? data.features : [];
        } catch (error) {
            if (ticket !== serial) return;
            state = {error: error.message};
            features = [];
        }
        redraw();
    }
    const initialize = function () {
        contexts.add(this);
    };
    const finalize = function () { contexts.delete(this); };
    api.registerWidget({
        name: 'userWeatherForecast', caption: 'Forecast',
        initFunction: initialize, finalizeFunction: finalize,
        renderHtml: function () {
            const planner = new URL('weather.html', import.meta.url).href;
            if (state.error) return `<div class="seabird-weather-controller">${escape(state.error)}<br><a target="seabird-weather" href="${escape(planner)}">Passage weather</a></div>`;
            const {meta, choice, point, pointError} = state;
            const times = meta.products[choice.layer].times;
            const options = times.map(time => `<option value="${time}" ${time === choice.time ? 'selected' : ''}>${escape(time.replace('T', ' ').replace('Z', ' UTC'))}</option>`).join('');
            const layers = Object.keys(meta.products).map(layer => `<option ${layer === choice.layer ? 'selected' : ''}>${escape(layer)}</option>`).join('');
            const passageInfo = state.planned ? `<div>${escape(state.planned.name)}: ${escape(state.passageError || `departure ${state.passage?.departure}; ETA weather`)}</div>` : '';
            return `<div class="seabird-weather-controller"><select aria-label="Forecast time" data-weather-action="time">${options}</select><select aria-label="Weather layer" data-weather-action="layer">${layers}</select><label><input type="checkbox" data-weather-action="enabled" ${choice.enabled ? 'checked' : ''}>Overlay</label><div>${escape(point ? summary(point.products) : pointError)}</div><small>${escape(choice.layer)} run ${escape(meta.products[choice.layer].run)}; downloaded ${meta.age_hours} h ago${meta.stale ? '; STALE' : ''}${meta.products[choice.layer].expired ? '; EXPIRED' : ''}</small>${passageInfo}<a target="seabird-weather" href="${escape(planner)}">Passage weather</a></div>`;
        },
    });
    api.registerWidget({
        name: 'userWeatherOverlay', type: 'map',
        initFunction: function () { contexts.add(this); }, finalizeFunction: finalize,
        renderCanvas: function () {
            const context = this.getContext();
            const scale = this.getScale();
            const dimensions = this.getDimensions();
            context.save();
            context.font = `${12 * scale}px sans-serif`;
            for (const feature of features) {
                const [lon, lat] = feature.geometry.coordinates;
                const pixel = this.lonLatToPixel(lon, lat);
                if (pixel[0] < 0 || pixel[1] < 0 || pixel[0] > dimensions[0] || pixel[1] > dimensions[1]) continue;
                const values = feature.properties;
                context.save();
                context.translate(pixel[0], pixel[1]);
                context.strokeStyle = '#ffffff';
                context.fillStyle = values.layer === 'currents' ? '#157b50' : '#175fa6';
                if (values.layer === 'waves') {
                    if (Number.isFinite(values.height_m)) {
                        const label = `${values.height_m.toFixed(1)}m`;
                        context.lineWidth = 3 * scale;
                        context.strokeText(label, 0, 0);
                        context.fillText(label, 0, 0);
                    }
                } else if (Number.isFinite(values.direction_deg)) {
                    const to = values.direction_deg + (values.layer === 'wind' ? 180 : 0);
                    context.rotate(to * Math.PI / 180 + this.getRotation());
                    context.beginPath();
                    context.moveTo(0, -12 * scale);
                    context.lineTo(5 * scale, 5 * scale);
                    context.lineTo(0, 2 * scale);
                    context.lineTo(-5 * scale, 5 * scale);
                    context.closePath();
                    context.lineWidth = 2 * scale;
                    context.stroke();
                    context.fill();
                    context.rotate(-(to * Math.PI / 180 + this.getRotation()));
                    context.fillText(`${values.speed_kn.toFixed(0)}`, 7 * scale, 5 * scale);
                }
                context.restore();
            }
            if (state.passage && state.choice?.enabled) {
                const samples = state.passage.samples;
                context.beginPath();
                samples.forEach((sample, index) => {
                    const pixel = this.lonLatToPixel(sample.lon, sample.lat);
                    if (index === 0) context.moveTo(...pixel);
                    else context.lineTo(...pixel);
                });
                context.strokeStyle = '#ffffff';
                context.lineWidth = 5 * scale;
                context.stroke();
                context.strokeStyle = '#b34d18';
                context.lineWidth = 2 * scale;
                context.setLineDash([6 * scale, 4 * scale]);
                context.stroke();
                context.setLineDash([]);
                const stride = Math.max(1, Math.ceil(samples.length / 20));
                samples.forEach((sample, index) => {
                    if (index % stride !== 0 && index !== samples.length - 1) return;
                    const pixel = this.lonLatToPixel(sample.lon, sample.lat);
                    if (pixel[0] < 0 || pixel[1] < 0 || pixel[0] > dimensions[0] || pixel[1] > dimensions[1]) return;
                    const values = sample.products[state.choice.layer];
                    const label = state.choice.layer === 'waves' ?
                        (Number.isFinite(values?.height_m) ? `${values.height_m.toFixed(1)}m` : '--') :
                        (Number.isFinite(values?.speed_kn) ? `${values.speed_kn.toFixed(1)}kn` : '--');
                    context.fillStyle = '#b34d18';
                    context.strokeStyle = '#ffffff';
                    context.lineWidth = 3 * scale;
                    const text = `${sample.valid.slice(11, 16)}Z ${label}`;
                    context.strokeText(text, pixel[0] + 6 * scale, pixel[1] - 6 * scale);
                    context.fillText(text, pixel[0] + 6 * scale, pixel[1] - 6 * scale);
                });
            }
            context.restore();
        },
    });
    window.addEventListener('seabird-weather-change', refresh);
    window.addEventListener('storage', refresh);
    const timer = setInterval(refresh, 60000);
    refresh();
    return () => {
        clearInterval(timer);
        inputEvents.forEach(name => document.removeEventListener(name, handleInput, true));
        style.remove();
        window.removeEventListener('seabird-weather-change', refresh);
        window.removeEventListener('storage', refresh);
        contexts.clear();
        serial++;
    };
}