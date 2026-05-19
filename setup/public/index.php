<?php

/**
 * Front controller for the bundled webtrees image.
 *
 * Bootstraps the composer autoloader and dispatches to webtrees via
 * the modern `Webtrees::new()->run(PHP_SAPI)` entry point. The
 * composer manifest pins `fisharebest/webtrees: ~2.2.0`, so the
 * minimum supported runtime API is the 2.2 line.
 */

declare(strict_types=1);

use Fisharebest\Webtrees\Webtrees;

use function dirname;

(static function () {
    require dirname(__DIR__) . '/vendor/autoload.php';

    return Webtrees::new()->run(PHP_SAPI);
})();
