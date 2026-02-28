" Syntax highlighting for pi chat buffer
if exists('b:current_syntax')
  finish
endif

" Headers
syntax match piChatH1 /^# .*$/ 
syntax match piChatH2 /^## .*$/
syntax match piChatH3 /^### .*$/

" Bold
syntax match piChatBold /\*\*.\{-}\*\*/

" Italic
syntax match piChatItalic /\*[^*]\+\*/

" Inline code
syntax match piChatInlineCode /`[^`]\+`/

" Code blocks
syntax region piChatCodeBlock start=/^```/ end=/^```/ contains=piChatCodeLang
syntax match piChatCodeLang /```\zs\w\+/ contained

" Horizontal rule
syntax match piChatHR /^---$/

" Emoji headers (our chat format)
syntax match piChatUserHeader /^## 👤.*$/
syntax match piChatAssistantHeader /^## 🤖.*$/

" Tool indicators
syntax match piChatToolRun /^\*\*🔧.*\*\*$/
syntax match piChatToolOk /^\*\*✅.*\*\*$/
syntax match piChatToolErr /^\*\*❌.*\*\*$/

" Status messages
syntax match piChatStatus /^\*[^*].*\*$/

" Blockquotes (thinking)
syntax match piChatQuote /^> .*/

" Links
syntax match piChatLink /\[.\{-}\](.\{-})/

" Highlight links
highlight default link piChatH1 Title
highlight default link piChatH2 Title
highlight default link piChatH3 Title
highlight default link piChatBold Bold
highlight default link piChatItalic Italic
highlight default link piChatInlineCode Special
highlight default link piChatCodeBlock Comment
highlight default link piChatCodeLang Type
highlight default link piChatHR NonText
highlight default link piChatUserHeader PiUser
highlight default link piChatAssistantHeader PiAssistant
highlight default link piChatToolRun PiTool
highlight default link piChatToolOk PiTool
highlight default link piChatToolErr PiToolError
highlight default link piChatStatus PiMeta
highlight default link piChatQuote PiThinking
highlight default link piChatLink Underlined

let b:current_syntax = 'pi_chat'
