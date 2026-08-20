import { generateUrl } from '@nextcloud/router'
import { t } from '@nextcloud/l10n'
import { Permission, registerFileAction } from '@nextcloud/files'

const supportedMimeTypes = new Set([
  'application/msword',
  'application/vnd.ms-excel',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
])

registerFileAction({
  id: 'twinbox-eurooffice-open',
  displayName: () => t('twinbox_eurooffice_action', 'Open in EuroOffice'),
  iconSvgInline: () => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M4 3h16v18H4z"/></svg>',
  enabled: ({ nodes }) => nodes.length === 1
    && Boolean(nodes[0].permissions & Permission.READ)
    && supportedMimeTypes.has(nodes[0].mime),
  exec: ({ nodes }) => {
    const file = nodes[0]
    const path = encodeURIComponent(file.path || file.basename)
    const url = generateUrl('/apps/eurooffice/{fileId}', { fileId: file.id }) + `?file=${path}`
    window.open(url, '_blank', 'noopener,noreferrer')
    return true
  },
})
