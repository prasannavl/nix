<?php
class BackendCombinedConfig {
    public static function GetBackendCombinedConfig() {
        return array(
            'backends' => array(
                'a' => array(
                    'name' => 'BackendIMAP',
                ),
                'd' => array(
                    'name' => 'BackendCardDAV',
                ),
                'c' => array(
                    'name' => 'BackendCalDAV',
                ),
            ),
            'delimiter' => ':',
            'folderbackend' => array(
                SYNC_FOLDER_TYPE_INBOX => 'a',
                SYNC_FOLDER_TYPE_DRAFTS => 'a',
                SYNC_FOLDER_TYPE_WASTEBASKET => 'a',
                SYNC_FOLDER_TYPE_SENTMAIL => 'a',
                SYNC_FOLDER_TYPE_OUTBOX => 'a',
                SYNC_FOLDER_TYPE_TASK => 'c',
                SYNC_FOLDER_TYPE_APPOINTMENT => 'c',
                SYNC_FOLDER_TYPE_CONTACT => 'd',
                SYNC_FOLDER_TYPE_OTHER => 'a',
                SYNC_FOLDER_TYPE_USER_MAIL => 'a',
                SYNC_FOLDER_TYPE_USER_APPOINTMENT => 'c',
                SYNC_FOLDER_TYPE_USER_CONTACT => 'd',
                SYNC_FOLDER_TYPE_USER_TASK => 'c',
                SYNC_FOLDER_TYPE_UNKNOWN => 'a',
            ),
            'rootcreatefolderbackend' => 'a',
        );
    }
}
