import installWeather from './weather.mjs';
import * as previous from './user-before-weather.mjs';

export default async function (api) {
    const cleanupPrevious = previous.default ? await previous.default(api) : undefined;
    const cleanupWeather = installWeather(api);
    return () => {
        cleanupWeather();
        if (typeof cleanupPrevious === 'function') cleanupPrevious();
    };
}