const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const dartSource = fs.readFileSync(
  path.join(__dirname, '..', 'lib', 'app', 'embedded_webview.dart'),
  'utf8',
);
const marker = "static const String colorSchemeBridgeSource = r'''";
const markerOffset = dartSource.indexOf(marker);
assert.notEqual(markerOffset, -1, 'production bridge source is present');
const scriptOffset = markerOffset + marker.length;
const scriptEnd = dartSource.indexOf("''';", scriptOffset);
assert.notEqual(scriptEnd, -1, 'production bridge source is terminated');
const bridgeTemplate = dartSource.slice(scriptOffset, scriptEnd);
const liveMarker = /static const String colorSchemeLiveUpdateSource\s*=\s*r'''/;
const liveMarkerMatch = liveMarker.exec(dartSource);
assert.ok(liveMarkerMatch, 'production live-update source is present');
const liveOffset = liveMarkerMatch.index + liveMarkerMatch[0].length;
const liveEnd = dartSource.indexOf("''';", liveOffset);
assert.notEqual(liveEnd, -1, 'production live-update source is terminated');
const liveTemplate = dartSource.slice(liveOffset, liveEnd);

function executeBridge(documentOrigin) {
  const nativeQueries = new Map();
  const window = {
    location: { origin: documentOrigin },
    matchMedia(media) {
      if (!nativeQueries.has(media)) {
        nativeQueries.set(media, new EventTarget());
      }
      return nativeQueries.get(media);
    },
  };
  const originalMatchMedia = window.matchMedia;
  const trustedOrigin = 'http://127.0.0.1:3001';
  const source = bridgeTemplate
    .replaceAll('__SUBDOCK_INITIAL_DARK__', 'true')
    .replaceAll(
      '__SUBDOCK_TRUSTED_ORIGIN__',
      JSON.stringify(trustedOrigin),
    );
  const context = vm.createContext({ window, EventTarget, Event, Object, Boolean, Set });
  vm.runInContext(source, context, { filename: 'production-color-scheme-bridge.js' });
  return { context, nativeQueries, originalMatchMedia, window };
}

test('trusted frontend gets initial and live dark-scheme notifications', () => {
  const { context, nativeQueries, window } = executeBridge(
    'http://127.0.0.1:3001',
  );
  const query = '(prefers-color-scheme: dark)';
  const dark = window.matchMedia(query);
  assert.equal(dark.matches, true);

  let modern;
  let legacy;
  let property;
  dark.addEventListener('change', (event) => {
    modern = [event.matches, event.media];
  });
  dark.addListener((event) => {
    legacy = [event.matches, event.media];
  });
  dark.onchange = (event) => {
    property = [event.matches, event.media];
  };
  const updateScript = liveTemplate
    .replaceAll(
      '__SUBDOCK_TRUSTED_ORIGIN__',
      JSON.stringify('http://127.0.0.1:3001'),
    )
    .replaceAll('__SUBDOCK_NEXT_DARK__', 'false');
  window.location.origin = 'https://example.com';
  vm.runInContext(updateScript, context, { filename: 'production-live-theme-update.js' });
  assert.equal(dark.matches, true, 'foreign origin cannot receive a live update');
  window.location.origin = 'http://127.0.0.1:3001';
  vm.runInContext(updateScript, context, { filename: 'production-live-theme-update.js' });

  assert.equal(dark.matches, false);
  assert.deepEqual(modern, [false, query]);
  assert.deepEqual(legacy, [false, query]);
  assert.deepEqual(property, [false, query]);

  const unrelated = '(min-width: 768px)';
  const native = window.matchMedia(unrelated);
  let unrelatedChange = false;
  native.addEventListener('change', () => {
    unrelatedChange = true;
  });
  assert.equal(window.matchMedia(unrelated), native);
  native.dispatchEvent(new Event('change'));
  assert.equal(unrelatedChange, true);
  assert.equal(nativeQueries.get(unrelated), native);
});

test('foreign document receives no theme bootstrap or matchMedia override', () => {
  const { context, originalMatchMedia, window } = executeBridge(
    'https://example.com',
  );
  assert.equal(window.matchMedia, originalMatchMedia);
  assert.equal(context.__subDockSetColorScheme, undefined);
  const liveUpdate = liveTemplate
    .replaceAll(
      '__SUBDOCK_TRUSTED_ORIGIN__',
      JSON.stringify('http://127.0.0.1:3001'),
    )
    .replaceAll('__SUBDOCK_NEXT_DARK__', 'true');
  assert.doesNotThrow(() =>
    vm.runInContext(liveUpdate, context, { filename: 'production-live-theme-update.js' }),
  );
  assert.equal(context.__subDockSetColorScheme, undefined);
  const query = '(prefers-color-scheme: dark)';
  const nativeResult = window.matchMedia(query);
  assert.equal(nativeResult.matches, undefined);
});
