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

    return Webtrees::new()->run(PHP_SAPI);
})();
