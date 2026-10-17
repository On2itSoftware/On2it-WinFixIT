' =======================================================================================
' IMPORT_WinFixIT_RTFfile
' =======================================================================================
' PURPOSE:
'   Reads a DeBloater UI-GroupsAndOptions.rtf definition file and produces a formatted
'   Word document suitable for inclusion in the User Manual.
'
'   Recognised tags:
'       [GROUP - name]       -> Heading 1, page break before each group
'       [SELECT - mode]      -> Small italic note (ALL / NONE / DIY ONLY / ONE)
'       [OPTION - name]      -> Heading 2
'       [ALTERNATIVE - name] -> Heading 3
'       {/rtf1...}           -> Advice body text, inserted with RTF formatting preserved
'                               Bullet paragraphs  -> "Bulleted List" style
'                               Numbered paragraphs -> "Numbered List" style
'       ===...               -> Ignored (section divider in source file only)
'
' HOW TO USE:
'   1. Open your Word template.
'   2. Press Alt+F11 to open the VBA editor.
'   3. Insert -> Module, then paste this entire file.
'   4. Press F5 (or run Convert_RTFDefinitionToWord) and choose the .rtf file.
' =======================================================================================

Sub IMPORT_WinFixIT_RTFfile()

    ' --- Pick the source file ---
    Dim fd As FileDialog
    Set fd = Application.FileDialog(msoFileDialogFilePicker)
    fd.Title = "Select DeBloater RTF Definition File"
    fd.Filters.Clear
    fd.Filters.Add "RTF/Text Files", "*.rtf;*.txt"
    fd.Filters.Add "All Files", "*.*"
    fd.AllowMultiSelect = False
    If fd.Show <> -1 Then Exit Sub
    Dim filePath As String
    filePath = fd.SelectedItems(1)

    ' --- Create new document based on the same template as the calling document ---
    ' (ensures custom styles like "Bulleted List" / "Numbered List" are available)
    Dim newDoc As Document
    Set newDoc = Documents.Add(Template:=ActiveDocument.AttachedTemplate.FullName)
    newDoc.Activate
    newDoc.Content.Delete   ' Remove the default empty paragraph

    ' --- Temp file for RTF fragments ---
    Dim tempFile As String
    tempFile = Environ("TEMP") & "\DeBloater_RTF_Temp.rtf"

    ' --- Parse and build ---
    Dim fileNum As Integer
    fileNum = FreeFile
    Open filePath For Input As #fileNum

    Dim lineText  As String
    Dim trimLine  As String
    Dim inRTF     As Boolean
    Dim rtfBlock  As String
    Dim isFirst   As Boolean
    inRTF   = False
    rtfBlock = ""
    isFirst  = True

    Do While Not EOF(fileNum)
        Line Input #fileNum, lineText
        trimLine = Trim(lineText)

        ' Guard: if a structural tag or separator appears while inside an RTF block,
        ' the block was never properly closed in the source file — force-close it now.
        If inRTF Then
            Dim isStructural As Boolean
            isStructural = (Left(trimLine, 1) = "[" And Right(trimLine, 1) = "]") _
                        Or Left(trimLine, 3) = "==="
            If isStructural Then
                inRTF = False
                rtfBlock = rtfBlock & "}" & vbCrLf  ' synthesise missing closing brace
                InsertRTFBlock newDoc, rtfBlock, tempFile
                rtfBlock = ""
            End If
        End If

        If Not inRTF Then

            ' ---- Structural tags ----
            If Left(trimLine, 1) = "[" And Right(trimLine, 1) = "]" Then

                Dim dashPos As Integer
                dashPos = InStr(trimLine, " - ")

                If dashPos > 0 Then
                    Dim tagType As String
                    Dim tagName As String
                    tagType = Mid(trimLine, 2, dashPos - 2)
                    tagName = Mid(trimLine, dashPos + 3, Len(trimLine) - dashPos - 3)

                    Select Case tagType

                        Case "GROUP"
                            If Not isFirst Then
                                Selection.InsertBreak Type:=wdPageBreak
                            End If
                            isFirst = False
                            Selection.Style = newDoc.Styles("Heading 2")
                            Selection.TypeText tagName
                            Selection.TypeParagraph
                            Selection.Style = newDoc.Styles("Normal")

                        Case "OPTION"
                            Selection.EndKey Unit:=wdStory
                            Selection.TypeParagraph
                            Selection.Style = newDoc.Styles("Heading 3")
                            Selection.TypeText tagName
                            Selection.TypeParagraph
                            Selection.Style = newDoc.Styles("Normal")

                        Case "ALTERNATIVE"
                            Selection.EndKey Unit:=wdStory
                            Selection.TypeParagraph
                            Selection.Style = newDoc.Styles("Heading 4")
                            Selection.TypeText tagName
                            Selection.TypeParagraph
                            Selection.Style = newDoc.Styles("Normal")

                        Case "SELECT"
                            ' Intentionally ignored — SELECT mode is not shown in the manual

                    End Select
                End If

            ' ---- Start of RTF block ----
            ElseIf Left(trimLine, 7) = "{\rtf1\" Then
                inRTF = True
                rtfBlock = lineText & vbCrLf

            ' ---- Section dividers (===) - skip ----
            ElseIf Left(trimLine, 3) = "===" Then
                ' Intentionally ignored

            End If

        Else
            ' ---- Collecting RTF block lines ----
            rtfBlock = rtfBlock & lineText & vbCrLf

            ' Closing brace on its own line signals end of RTF block
            If trimLine = "}" Or trimLine = "} " Then
                inRTF = False
                InsertRTFBlock newDoc, rtfBlock, tempFile
                rtfBlock = ""
            End If

        End If
    Loop

    Close #fileNum
    If Dir(tempFile) <> "" Then Kill tempFile

    ' Convert plain-text URLs to clickable Word hyperlinks
    ConvertURLsToHyperlinks newDoc

    ' Fix garbled UTF-8 non-breaking hyphens (â€' = U+2011 misread as Windows-1252)
    newDoc.Content.Find.Execute _
        FindText:=Chr(226) & ChrW(8364) & ChrW(8216), _
        ReplaceWith:=ChrW(8209), _
        Replace:=wdReplaceAll

    ' Collapse consecutive blank paragraphs left by RTF \par sequences
    Dim pass As Integer
    For pass = 1 To 5
        newDoc.Content.Find.Execute _
            FindText:="^p^p", ReplaceWith:="^p", Replace:=wdReplaceAll
    Next pass

    ' Move cursor to top
    Selection.HomeKey Unit:=wdStory

    MsgBox "Conversion complete!" & vbCrLf & vbCrLf & _
           "Document: " & newDoc.Name, vbInformation, "DeBloater - RTF to Word"

End Sub


' =======================================================================================
' InsertRTFBlock
' Writes an RTF fragment to a temp file, inserts it, then post-processes bullet and
' numbered paragraphs into proper Word list styles.
' =======================================================================================
Private Sub InsertRTFBlock(doc As Document, rtfText As String, tempFile As String)

    ' Write RTF fragment to temp file
    Dim fOut As Integer
    fOut = FreeFile
    Open tempFile For Output As #fOut
    Print #fOut, rtfText
    Close #fOut

    ' Count paragraphs before insertion so we can identify the new ones afterwards
    Dim parasBefore As Integer
    parasBefore = doc.Paragraphs.Count

    Selection.InsertFile FileName:=tempFile, ConfirmConversions:=False

    Dim parasAfter As Integer
    parasAfter = doc.Paragraphs.Count

    ' Post-process in reverse so that deleting a blank paragraph does not
    ' shift the index of paragraphs we have not yet visited
    Dim i As Integer
    For i = parasAfter To parasBefore Step -1
        PostProcessParagraph doc, doc.Paragraphs(i)
    Next i

    ' Move to end and ensure next tag starts on a fresh empty paragraph
    Selection.EndKey Unit:=wdStory
    Selection.TypeParagraph
    Selection.Style = doc.Styles("Normal")

End Sub


' =======================================================================================
' PostProcessParagraph
' Checks whether a paragraph starts with a bullet (•) or a number (1. 2. etc.)
' and applies the appropriate list style, removing the leading marker from the text
' while preserving any bold/italic formatting on the remaining content.
' =======================================================================================
Private Sub PostProcessParagraph(doc As Document, para As Paragraph)

    Dim rng As Range
    Set rng = para.Range

    ' Paragraph containing only a paragraph mark — delete it
    If rng.End <= rng.Start + 1 Then
        If doc.Paragraphs.Count > 1 Then para.Range.Delete
        Exit Sub
    End If

    ' Read the paragraph text excluding the trailing paragraph mark
    Dim fullText As String
    fullText = doc.Range(rng.Start, rng.End - 1).Text

    Dim trimmed As String
    trimmed = LTrim(fullText)  ' Left-trim to find the first real character

    ' Blank paragraph — delete it; style spacing handles visual separation
    If Len(trimmed) = 0 Then
        If doc.Paragraphs.Count > 1 Then para.Range.Delete
        Exit Sub
    End If

    Dim firstChar As String
    firstChar = Left(trimmed, 1)

    ' ---- Bullet paragraph ----
    ' ChrW(8226) = proper Unicode bullet
    ' Chr(149)   = Windows-1252 bullet
    ' Chr(226)   = first byte of garbled UTF-8 bullet (â€¢) when RTF read as ANSI
    Dim isBullet As Boolean
    isBullet = (firstChar = ChrW(8226)) Or _
               (firstChar = Chr(149)) Or _
               (firstChar = Chr(226) And Left(trimmed, 3) = Chr(226) & ChrW(8364) & Chr(162))

    If isBullet Then
        StripLeadingMarker doc, rng, IsBullet:=True   ' strip first — positions correct
        ApplyStyleKeepFormatting doc, para, "Bulleted List"
        Exit Sub
    End If

    ' ---- Numbered paragraph ----
    If trimmed Like "[0-9].*" Or trimmed Like "[0-9][0-9].*" Then
        ApplyStyleKeepFormatting doc, para, "Numbered List"
        On Error Resume Next
        para.Range.ListFormat.RemoveNumbers wdNumberParagraph
        On Error GoTo 0
        Exit Sub
    End If

    ' ---- Regular paragraph — apply Normal, preserving bold/italic ----
    ApplyStyleKeepFormatting doc, para, "Normal"

End Sub


' =======================================================================================
' StripLeadingMarker
' Deletes the leading bullet/number characters from a paragraph range in one operation,
' leaving all formatting on the remaining text intact.
' =======================================================================================
Private Sub StripLeadingMarker(doc As Document, paraRng As Range, IsBullet As Boolean)

    ' Read text up to (but not including) the paragraph mark
    Dim txt As String
    txt = doc.Range(paraRng.Start, paraRng.End - 1).Text

    ' Count how many characters to delete from the front:
    '   spaces / tabs / bullet char / number+period / trailing space after marker
    Dim skipCount As Integer
    skipCount = 0
    Dim pastMarker As Boolean
    pastMarker = False

    Dim idx As Integer
    For idx = 1 To Len(txt)
        Dim ch As String
        ch = Mid(txt, idx, 1)

        If Not pastMarker Then
            ' Still looking for the marker itself
            If ch = " " Or ch = Chr(9) Then
                skipCount = skipCount + 1  ' Leading whitespace before marker
            ElseIf IsBullet And (ch = ChrW(8226) Or ch = Chr(149)) Then
                skipCount = skipCount + 1  ' The bullet character
                pastMarker = True
            ElseIf IsBullet And ch = Chr(226) Then
                skipCount = skipCount + 3  ' Garbled UTF-8 bullet = 3 chars (â€¢)
                idx = idx + 2              ' Skip the next 2 chars in the loop
                pastMarker = True
            ElseIf Not IsBullet And (ch >= "0" And ch <= "9") Then
                skipCount = skipCount + 1  ' Digit(s) of number
            ElseIf Not IsBullet And ch = "." Then
                skipCount = skipCount + 1  ' Period after number
                pastMarker = True
            Else
                Exit For  ' Unexpected character before marker — stop
            End If
        Else
            ' Past the marker — skip any trailing spaces/tabs before content
            If ch = " " Or ch = Chr(9) Then
                skipCount = skipCount + 1
            Else
                Exit For  ' Hit real content — stop
            End If
        End If
    Next idx

    ' Delete the marker characters in one operation (preserves formatting on the rest)
    If skipCount > 0 Then
        doc.Range(paraRng.Start, paraRng.Start + skipCount).Delete
    End If

End Sub


' =======================================================================================
' ApplyStyleSafe
' Applies a named style, falling back to a built-in equivalent if the name is not found.
' Shows a one-time warning so the user knows the exact style name to fix if needed.
' =======================================================================================
Private Sub ApplyStyleSafe(doc As Document, para As Paragraph, styleName As String)

    On Error GoTo StyleNotFound
    para.Style = doc.Styles(styleName)
    Exit Sub

StyleNotFound:
    ' Style not found — list available styles and fall back to built-in equivalent
    Dim fallback As String
    If InStr(LCase(styleName), "bullet") > 0 Then
        fallback = "List Bullet"
    Else
        fallback = "List Number"
    End If

    Static warned As Boolean
    If Not warned Then
        Dim styleList As String
        Dim s As Style
        For Each s In doc.Styles
            If s.Type = wdStyleTypeParagraph Then
                If InStr(LCase(s.NameLocal), "list") > 0 Or _
                   InStr(LCase(s.NameLocal), "bullet") > 0 Or _
                   InStr(LCase(s.NameLocal), "number") > 0 Then
                    styleList = styleList & "  " & s.NameLocal & vbCrLf
                End If
            End If
        Next s
        MsgBox "Style '" & styleName & "' not found. Using '" & fallback & "' instead." & vbCrLf & vbCrLf & _
               "List-related styles in this document:" & vbCrLf & styleList & vbCrLf & _
               "Update the style names in the macro to match.", _
               vbExclamation, "Style Not Found"
        warned = True
    End If

    On Error Resume Next
    para.Style = doc.Styles(fallback)
    On Error GoTo 0

End Sub


' =======================================================================================
' ConvertURLsToHyperlinks
' Scans the document for http://, https://, and www. patterns and converts each to a
' clickable Word hyperlink.  URLs embedded mid-sentence are handled by extending the
' match character by character until whitespace is reached.
' =======================================================================================
Private Sub ConvertURLsToHyperlinks(doc As Document)

    Dim prefixes(2) As String
    prefixes(0) = "https://"   ' processed first so https:// is linked before http://
    prefixes(1) = "http://"
    prefixes(2) = "www."       ' processed last; already-linked www. inside http://www. is skipped

    Dim p          As Integer
    Dim searchRng  As Range
    Dim matchStart As Long
    Dim urlEnd     As Long
    Dim contentEnd As Long
    Dim nextCh     As String
    Dim lastCh     As String
    Dim urlRng     As Range
    Dim urlText    As String
    Dim address    As String

    For p = 0 To 2

        Set searchRng = doc.Content

        Do While searchRng.Find.Execute( _
                FindText:=prefixes(p), MatchCase:=False, Forward:=True)

            matchStart = searchRng.Start

            If IsInsideHyperlink(doc, matchStart) Then
                ' Already linked — skip past the match and keep searching
                searchRng.Collapse wdCollapseEnd
            Else
                ' Extend the range to the end of the URL
                urlEnd     = searchRng.End
                contentEnd = doc.Content.End - 1

                Do While urlEnd < contentEnd
                    nextCh = doc.Range(urlEnd, urlEnd + 1).Text
                    Select Case nextCh
                        Case " ", Chr(9), Chr(13), Chr(11), Chr(7), Chr(160)
                            Exit Do     ' whitespace / paragraph / cell terminator
                        Case Else
                            urlEnd = urlEnd + 1
                    End Select
                Loop

                ' Strip trailing punctuation unlikely to be part of the URL
                Do While urlEnd > matchStart
                    lastCh = doc.Range(urlEnd - 1, urlEnd).Text
                    If InStr(".,;:!?)'""", lastCh) > 0 Then
                        urlEnd = urlEnd - 1
                    Else
                        Exit Do
                    End If
                Loop

                Set urlRng = doc.Range(matchStart, urlEnd)
                urlText    = urlRng.Text

                If LCase(Left(urlText, 4)) = "www." Then
                    address = "http://" & urlText
                Else
                    address = urlText
                End If

                On Error Resume Next
                doc.Hyperlinks.Add Anchor:=urlRng, Address:=address
                On Error GoTo 0

                ' Restart search from just after this URL
                Set searchRng = doc.Range(urlEnd, doc.Content.End)
            End If

        Loop
    Next p

End Sub


' =======================================================================================
' IsInsideHyperlink
' Returns True if the given character position falls within an existing hyperlink.
' Used to prevent double-linking (e.g. www. inside an already-linked http://www. URL).
' =======================================================================================
Private Function IsInsideHyperlink(doc As Document, pos As Long) As Boolean
    Dim hl As Hyperlink
    IsInsideHyperlink = False
    For Each hl In doc.Hyperlinks
        If hl.Range.Start <= pos And hl.Range.End >= pos Then
            IsInsideHyperlink = True
            Exit Function
        End If
    Next hl
End Function


' =======================================================================================
' InsertSelectNote
' Inserts the [SELECT - mode] line as a small grey italic note.
' =======================================================================================
Private Sub InsertSelectNote(doc As Document, selectMode As String)

    Dim noteText As String
    Select Case selectMode
        Case "ALL"      : noteText = "Default: ALL options recommended"
        Case "NONE"     : noteText = "Default: No options selected  (PRO feature)"
        Case "DIY ONLY" : noteText = "DIY ONLY — Windows does not permit automation; manual steps provided in each option"
        Case "ONE"      : noteText = "Select ONE option from this group"
        Case Else       : noteText = "Selection mode: " & selectMode
    End Select

    With Selection
        .Font.Italic = True
        .Font.Size   = 9
        .Font.Color  = RGB(120, 120, 120)
        .TypeText noteText
        .Font.Italic = False
        .Font.Size   = 11
        .Font.Color  = wdColorAutomatic
        .TypeParagraph
    End With

End Sub
