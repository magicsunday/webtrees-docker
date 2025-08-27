<?php

/**
 * This file is part of the package magicsunday/webtrees-base.
 *
 * For the full copyright and license information, please read the
 * LICENSE file that was distributed with this source code.
 */

use Fisharebest\Webtrees\Webtrees;

// Set up the application for the frontend
(static function () {
    require dirname(__DIR__) . '/vendor/autoload.php';

    // Webtrees below 2.2.0
    if (version_compare(Webtrees::VERSION, '2.2.0', '<') === true) {
        $webtrees = new Webtrees();
        $webtrees->bootstrap();

        if (PHP_SAPI === 'cli') {
            $webtrees->cliRequest();
        } else {
            $webtrees->httpRequest();
        }
    } else {
        return Webtrees::new()->run(PHP_SAPI);
    }
})();
