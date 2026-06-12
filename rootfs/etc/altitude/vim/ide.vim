" Altitude Vim IDE profile.
set nocompatible
set number
set ruler
set showcmd
set wildmenu
set hidden
set splitbelow
set splitright
set expandtab
set shiftwidth=2
set tabstop=2
set softtabstop=2
set autoindent
set incsearch
set hlsearch
set laststatus=2
set confirm
set mouse=a
set updatetime=500
set statusline=Altitude\ Vim\ IDE\ \|\ %f\ %m%r%h%w\ \|\ %l:%c
syntax on
filetype plugin indent on

let mapleader = " "
let g:altitude_source_root = get(g:, 'altitude_source_root', $ALTITUDE_AGENT_SOURCE_ROOT)
if empty(g:altitude_source_root)
  let g:altitude_source_root = '/root/minibash-linux'
endif
let g:altitude_keyboard_layout = get(g:, 'altitude_keyboard_layout', $ALTITUDE_KEYBOARD_LAYOUT)
if empty(g:altitude_keyboard_layout)
  let g:altitude_keyboard_layout = 'unknown'
endif

function! s:Scratch(name, lines) abort
  botright new
  execute 'file ' . a:name
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal filetype=sh
  call setline(1, empty(a:lines) ? ['(no output)'] : a:lines)
  normal! gg
endfunction

function! s:Run(label, command) abort
  let l:lines = ['$ ' . a:command, '']
  let l:lines += systemlist(a:command)
  if v:shell_error
    call add(l:lines, '')
    call add(l:lines, 'exit: ' . v:shell_error)
  endif
  call s:Scratch('[Altitude] ' . a:label, l:lines)
endfunction

function! s:ProjectCommand(command) abort
  return 'cd ' . shellescape(g:altitude_source_root) . ' && ' . a:command
endfunction

function! s:ProjectFiles() abort
  if executable('rg')
    let l:cmd = s:ProjectCommand('rg --files')
  else
    let l:cmd = s:ProjectCommand('find . -type f | sed "s#^\./##"')
  endif
  return filter(systemlist(l:cmd), 'v:val !~# "^\\.git/"')
endfunction

function! s:OpenProjectFile(path) abort
  if empty(a:path)
    echo "AltitudeOpen: no file selected"
    return
  endif
  execute 'edit ' . fnameescape(g:altitude_source_root . '/' . a:path)
endfunction

function! s:FindFile(query) abort
  let l:query = empty(a:query) ? input('File: ') : a:query
  let l:files = s:ProjectFiles()
  if !empty(l:query)
    let l:files = filter(l:files, 'v:val =~? l:query')
  endif
  if empty(l:files)
    echo "AltitudeFiles: no match"
    return
  endif
  if len(l:files) == 1
    call s:OpenProjectFile(l:files[0])
    return
  endif
  let l:menu = ['Altitude files:'] + map(copy(l:files[0:19]), 'printf("%2d. %s", v:key + 1, v:val)')
  let l:choice = inputlist(l:menu)
  if l:choice > 0 && l:choice <= len(l:files[0:19])
    call s:OpenProjectFile(l:files[l:choice - 1])
  endif
endfunction

function! s:SearchProject(query) abort
  let l:query = empty(a:query) ? input('Search: ') : a:query
  if empty(l:query)
    echo "AltitudeSearch: empty query"
    return
  endif
  if executable('rg')
    call s:Run('search ' . l:query, s:ProjectCommand('rg -n ' . shellescape(l:query)))
  else
    call s:Run('search ' . l:query, s:ProjectCommand('grep -RIn ' . shellescape(l:query) . ' recipes scripts rootfs packages tests docs 2>/dev/null'))
  endif
endfunction

function! s:BashRun(arg) abort
  let l:path = empty(a:arg) ? expand('%') : a:arg
  if empty(l:path)
    echo "AltitudeBashRun: no script selected"
    return
  endif
  call s:Run('bash run ' . l:path, '/bin/alt-agent ide language bash run ' . shellescape(l:path))
endfunction

function! s:BashNew(arg) abort
  let l:path = empty(a:arg) ? input('New Bash file: ') : a:arg
  if empty(l:path)
    echo "AltitudeBashNew: no path selected"
    return
  endif
  if l:path =~# '^/' || l:path =~# '\(^\|/\)\.\.\(/\|$\)'
    echo "AltitudeBashNew: unsafe path"
    return
  endif
  let l:full = g:altitude_source_root . '/' . l:path
  if filereadable(l:full)
    execute 'edit ' . fnameescape(l:full)
    return
  endif
  call mkdir(fnamemodify(l:full, ':h'), 'p')
  call writefile(['#!/usr/bin/env bash', 'set -euo pipefail', ''], l:full)
  call setfperm(l:full, 'rwxr-xr-x')
  execute 'edit ' . fnameescape(l:full)
endfunction

function! s:RecipeFromPath() abort
  let l:path = expand('%:p')
  let l:root = fnamemodify(g:altitude_source_root, ':p')
  if l:path =~# '^' . escape(l:root . 'recipes/', '\')
    let l:rest = substitute(l:path, '^' . escape(l:root . 'recipes/', '\'), '', '')
    return split(l:rest, '/')[0]
  endif
  return ''
endfunction

function! s:RecipeArg(arg) abort
  if !empty(a:arg)
    return a:arg
  endif
  let l:recipe = s:RecipeFromPath()
  if empty(l:recipe)
    let l:recipe = input('Recipe: ')
  endif
  return l:recipe
endfunction

function! s:Build(arg) abort
  let l:recipe = s:RecipeArg(a:arg)
  if empty(l:recipe)
    echo "AltitudeBuild: no recipe selected"
    return
  endif
  call s:Run('build ' . l:recipe, '/bin/alt-agent build-recipe ' . shellescape(l:recipe))
endfunction

function! s:Palette() abort
  let l:items = [
        \ ['Status', 'AltitudeStatus'],
        \ ['Open file', 'AltitudeFiles'],
        \ ['Search project', 'AltitudeSearch'],
        \ ['Build recipe', 'AltitudeBuild'],
        \ ['Dev check', 'AltitudeDevCheck'],
        \ ['Shell lint', 'AltitudeShellLint'],
        \ ['Bash run current', 'AltitudeBashRun'],
        \ ['Bash new file', 'AltitudeBashNew'],
        \ ['Publish staging', 'AltitudePublish'],
        \ ['Systemd audit', 'AltitudeAudit'],
        \ ['Graphical logs', 'AltitudeLogs'],
        \ ['Git status', 'AltitudeGit'],
        \ ['Keyboard layout', 'AltitudeKeyboard'],
        \ ]
  let l:menu = ['Altitude command palette:'] + map(copy(l:items), 'printf("%2d. %s", v:key + 1, v:val[0])')
  let l:choice = inputlist(l:menu)
  if l:choice > 0 && l:choice <= len(l:items)
    execute l:items[l:choice - 1][1]
  endif
endfunction

command! AltitudeStatus call s:Run('status', '/bin/alt-agent status')
command! AltitudeKeyboard call s:Run('keyboard', 'printf "layout=%s\nxkb=%s\n" "$ALTITUDE_KEYBOARD_LAYOUT" "$XKB_DEFAULT_LAYOUT"')
command! AltitudeDevEnv call s:Run('dev env', '/bin/alt-agent dev-env')
command! AltitudeDevCheck call s:Run('dev check', '/bin/alt-agent ide diagnostics run')
command! -nargs=* AltitudeShellLint call s:Run('shell lint', '/bin/alt-agent ide language bash lint ' . <q-args>)
command! -nargs=? AltitudeBashRun call s:BashRun(<q-args>)
command! -nargs=? AltitudeBashNew call s:BashNew(<q-args>)
command! -nargs=? AltitudeFiles call s:FindFile(<q-args>)
command! -nargs=? AltitudeSearch call s:SearchProject(<q-args>)
command! AltitudeRecipes call s:Run('recipes', '/bin/alt-agent recipes')
command! -nargs=? AltitudeBuild call s:Build(<q-args>)
command! AltitudePublish call s:Run('publish', '/bin/alt-agent publish-staging')
command! AltitudeAudit call s:Run('systemd audit', '/bin/alt-agent systemd-audit')
command! -nargs=? AltitudeLogs call s:Run('logs ' . (<q-args> ==# '' ? 'altitude-graphical.service' : <q-args>), '/bin/alt-agent logs ' . shellescape(<q-args> ==# '' ? 'altitude-graphical.service' : <q-args>))
command! AltitudeGit call s:Run('git status', 'cd ' . shellescape(g:altitude_source_root) . ' && git status --short')
command! AltitudePalette call s:Palette()
command! -nargs=* Altitude call s:Run('agent', '/bin/alt-agent ' . <q-args>)

nnoremap <C-p> :AltitudePalette<CR>
nnoremap <leader>as :AltitudeStatus<CR>
nnoremap <leader>ak :AltitudeKeyboard<CR>
nnoremap <leader>af :AltitudeFiles<CR>
nnoremap <leader>a/ :AltitudeSearch<CR>
nnoremap <leader>ar :AltitudeRecipes<CR>
nnoremap <leader>ab :AltitudeBuild<CR>
nnoremap <leader>ad :AltitudeDevCheck<CR>
nnoremap <leader>ac :AltitudeShellLint<CR>
nnoremap <leader>ax :AltitudeBashRun<CR>
nnoremap <leader>ap :AltitudePublish<CR>
nnoremap <leader>aa :AltitudeAudit<CR>
nnoremap <leader>ag :AltitudeGit<CR>
nnoremap <leader>al :AltitudeLogs<CR>

echo "Altitude Vim IDE [" . g:altitude_keyboard_layout . "]: Ctrl-P palette, <Space>af files, <Space>a/ search, <Space>ax bash run"
