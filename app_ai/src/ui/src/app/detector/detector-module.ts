import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatSnackBarModule } from '@angular/material/snack-bar';
import { DetectorComponent } from './detector-component/detector-component';
import { MatIconModule } from '@angular/material/icon'
import { MatSelectModule } from '@angular/material/select'
import { MatButtonModule } from '@angular/material/button';

// local
import { SharedModule } from '../shared/shared-module'
import { HttpClient, HttpClientModule } from '@angular/common/http';

@NgModule({
  declarations: [
    DetectorComponent
  ],
  imports: [
    CommonModule,
    MatSnackBarModule,
    MatIconModule,
    MatSelectModule,
    MatButtonModule,
    SharedModule,
    HttpClientModule
  ],
  exports: [
    DetectorComponent
  ]
})
export class DetectorModule { }
