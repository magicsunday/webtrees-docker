<?php

/**
 * This file is part of the package magicsunday/webtrees-base.
 *
 * For the full copyright and license information, please read the
 * LICENSE file that was distributed with this source code.
 */

// Set up the application for the frontend
call_user_func(static function () {
    require dirname(__DIR__) . '/vendor/fisharebest/webtrees/index.php';
});
