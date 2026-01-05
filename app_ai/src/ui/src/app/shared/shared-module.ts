import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatSnackBarModule } from '@angular/material/snack-bar';
import { MatIconModule } from '@angular/material/icon'

// local
import { FileUploader } from './file-uploader/file-uploader'
import { SelectComponent } from './option-selector/option-selector'
import { OptionComponent } from './option/option'

@NgModule({
  declarations: [
    FileUploader,
    SelectComponent,
    OptionComponent
  ],
  imports: [
    CommonModule,
    MatSnackBarModule,
    MatIconModule
  ],
  exports: [
    FileUploader,
    SelectComponent,
    OptionComponent
  ]
})
export class SharedModule { }
