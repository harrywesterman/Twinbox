import { createAppConfig } from '@nextcloud/vite-config'

export default createAppConfig(
  { main: 'src/main.js' },
  { appName: 'twinbox_eurooffice_action' },
)
